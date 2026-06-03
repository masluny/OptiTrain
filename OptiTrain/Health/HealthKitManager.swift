import Foundation
import HealthKit

@Observable
final class HealthKitManager {
    enum HealthError: Error {
        case unavailable
        case missingType(String)
    }

    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private(set) var isAuthorized = false

    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .vo2Max)!,
            HKObjectType.quantityType(forIdentifier: .height)!,
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.workoutType()
        ]
        if let temp = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            set.insert(temp)
        }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            set.insert(dob)
        }
        if let sex = HKObjectType.characteristicType(forIdentifier: .biologicalSex) {
            set.insert(sex)
        }
        return set
    }

    private var writeTypes: Set<HKSampleType> {
        [HKObjectType.workoutType()]
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        isAuthorized = true
    }

    // MARK: - Daily snapshot

    func dailyMetrics(for date: Date,
                      calendar: Calendar = .current,
                      precomputedWorkoutLoad: Double? = nil) async throws -> DailyMetrics {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        // Wide sleep window: yesterday noon → today 2pm. Catches late bedtimes, late wake-ups, and naps.
        let sleepWindowStart = calendar.date(byAdding: .hour, value: -12, to: dayStart)!
        let sleepWindowEnd = dayStart.addingTimeInterval(14 * 3600)

        // Every per-day query is wrapped in `tolerant`: HealthKit's most common
        // failure is "no data in window" (HKError 11), which we already coerce
        // to nil — but ANY other transient error from a single sub-query
        // shouldn't take down the whole day's row. Missing signals just become
        // nil and the engines downstream decide how to treat them.
        async let sleep = tolerant { try await self.sleepMetrics(start: sleepWindowStart, end: sleepWindowEnd) }
        async let hrv = tolerant { try await self.overnightHRV(start: sleepWindowStart, end: sleepWindowEnd) }
        async let rhr = tolerant { try await self.latestQuantity(.restingHeartRate, unit: HKUnit(from: "count/min"), in: DateInterval(start: calendar.date(byAdding: .day, value: -1, to: dayEnd)!, end: dayEnd)) }
        async let temp = tolerant { try await self.wristTemperatureDelta(on: date, calendar: calendar) }
        async let resp = tolerant { try await self.latestQuantity(.respiratoryRate, unit: HKUnit(from: "count/min"), in: DateInterval(start: sleepWindowStart, end: dayEnd)) }
        async let steps = tolerant { try await self.sum(.stepCount, unit: .count(), in: DateInterval(start: dayStart, end: dayEnd)) }
        async let kcal = tolerant { try await self.sum(.activeEnergyBurned, unit: .kilocalorie(), in: DateInterval(start: dayStart, end: dayEnd)) }

        // Workout load is the expensive query — caller can hand us a value
        // pre-computed once for the whole window, skipping the per-day query.
        let workoutLoad: Double
        if let precomputedWorkoutLoad {
            workoutLoad = precomputedWorkoutLoad
        } else {
            let dayWorkouts = (try? await workouts(in: DateInterval(start: dayStart, end: dayEnd))) ?? []
            workoutLoad = dayWorkouts.reduce(0.0) { $0 + load(for: $1) }
        }

        // Flatten the nested `T??` from `tolerant<T?>` back to a single optional
        // so the call site reads the way it always has.
        return DailyMetrics(
            date: dayStart,
            sleep: (await sleep).flatMap { $0 },
            overnightHRV: (await hrv).flatMap { $0 },
            restingHeartRate: (await rhr).flatMap { $0 },
            wristTemperatureDelta: (await temp).flatMap { $0 },
            respiratoryRate: (await resp).flatMap { $0 },
            steps: (await steps).flatMap { $0 }.map { Int($0) },
            activeEnergyKcal: (await kcal).flatMap { $0 },
            workoutLoad: workoutLoad
        )
    }

    func recentDailyMetrics(days: Int,
                            onDayComplete: (@Sendable (Int) -> Void)? = nil) async throws -> [DailyMetrics] {
        let calendar = Calendar.current
        guard days > 0 else { return [] }

        // Pull every workout for the window in ONE query, then build a per-day
        // load map. Previously we hit HealthKit with N extra workout queries
        // (one per day) — biggest single contributor to cold-start latency.
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let allWorkouts = (try? await workouts(in: DateInterval(start: start, end: end))) ?? []
        let loadByDay: [Date: Double] = allWorkouts.reduce(into: [:]) { partial, workout in
            let dayKey = calendar.startOfDay(for: workout.start)
            partial[dayKey, default: 0] += load(for: workout)
        }

        // Bounded parallelism: fan out up to N days at once. The whole loop
        // used to be strictly sequential, so 35 days × 200ms ≈ 7s. With a
        // window of 3 concurrent days, the same fetch finishes in ~3s — and we
        // don't flood HealthKit with so many simultaneous queries that the
        // store starts rate-limiting us. Tuned by hand on iPhone 17.
        let maxConcurrentDays = 3
        var ordered: [DailyMetrics?] = Array(repeating: nil, count: days)
        var nextOffset = 0
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, DailyMetrics).self) { group in
            // Prime the window.
            while nextOffset < min(maxConcurrentDays, days) {
                let offset = nextOffset
                let day = calendar.date(byAdding: .day, value: -offset, to: today)!
                let cachedLoad = loadByDay[calendar.startOfDay(for: day)] ?? 0
                group.addTask { [self] in
                    try Task.checkCancellation()
                    let metrics = try await dailyMetrics(for: day,
                                                         calendar: calendar,
                                                         precomputedWorkoutLoad: cachedLoad)
                    return (offset, metrics)
                }
                nextOffset += 1
            }

            // Drain + refill: as each day completes, kick off the next one.
            while let (offset, metrics) = try await group.next() {
                ordered[offset] = metrics
                completed += 1
                onDayComplete?(completed)

                if nextOffset < days {
                    let scheduledOffset = nextOffset
                    let day = calendar.date(byAdding: .day, value: -scheduledOffset, to: today)!
                    let cachedLoad = loadByDay[calendar.startOfDay(for: day)] ?? 0
                    group.addTask { [self] in
                        try Task.checkCancellation()
                        let metrics = try await dailyMetrics(for: day,
                                                             calendar: calendar,
                                                             precomputedWorkoutLoad: cachedLoad)
                        return (scheduledOffset, metrics)
                    }
                    nextOffset += 1
                }
            }
        }

        return ordered.compactMap { $0 }.reversed()
    }

    // MARK: - Sleep

    private func sleepMetrics(start: Date, end: Date) async throws -> SleepMetrics? {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    if Self.isNoData(error) { cont.resume(returning: []); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return nil }

        var inBed: TimeInterval = 0
        var asleep: TimeInterval = 0
        var deep: TimeInterval = 0
        var rem: TimeInterval = 0
        var core: TimeInterval = 0
        var awake: TimeInterval = 0
        var midpointStart: Date?
        var midpointEnd: Date?

        for s in samples {
            let dur = s.endDate.timeIntervalSince(s.startDate)
            guard let value = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            switch value {
            case .inBed: inBed += dur
            case .asleepDeep:
                deep += dur; asleep += dur
                midpointStart = min(midpointStart ?? s.startDate, s.startDate)
                midpointEnd = max(midpointEnd ?? s.endDate, s.endDate)
            case .asleepREM:
                rem += dur; asleep += dur
                midpointStart = min(midpointStart ?? s.startDate, s.startDate)
                midpointEnd = max(midpointEnd ?? s.endDate, s.endDate)
            case .asleepCore, .asleepUnspecified:
                core += dur; asleep += dur
                midpointStart = min(midpointStart ?? s.startDate, s.startDate)
                midpointEnd = max(midpointEnd ?? s.endDate, s.endDate)
            case .awake: awake += dur
            @unknown default: break
            }
        }
        // Fallback for older watchOS / iPhone-only sleep tracking: only `.inBed`
        // samples are present. Treat (inBed − awake) as asleep, bucketed as "core".
        if asleep == 0 && inBed > 0 {
            let derived = max(0, inBed - awake)
            asleep = derived
            core = derived
            if midpointStart == nil, let first = samples.first(where: { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }) {
                midpointStart = first.startDate
                midpointEnd = samples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }.map(\.endDate).max()
            }
        }
        let midpoint: Date? = {
            guard let s = midpointStart, let e = midpointEnd else { return nil }
            return Date(timeIntervalSince1970: (s.timeIntervalSince1970 + e.timeIntervalSince1970) / 2)
        }()
        return SleepMetrics(
            inBedDuration: inBed > 0 ? inBed : asleep,
            asleepDuration: asleep,
            deepDuration: deep,
            remDuration: rem,
            coreDuration: core,
            awakeDuration: awake,
            sleepMidpoint: midpoint
        )
    }

    // MARK: - HRV (overnight average of SDNN samples)

    private func overnightHRV(start: Date, end: Date) async throws -> Double? {
        let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    if Self.isNoData(error) { cont.resume(returning: []); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return nil }
        let unit = HKUnit.secondUnit(with: .milli)
        let values = samples.map { $0.quantity.doubleValue(for: unit) }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Wrist temperature (sleeping) — already a delta vs personal baseline

    private func wristTemperatureDelta(on date: Date, calendar: Calendar) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) else { return nil }
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let predicate = HKQuery.predicateForSamples(withStart: dayStart.addingTimeInterval(-12 * 3600), end: dayEnd)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error {
                    if Self.isNoData(error) { cont.resume(returning: []); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        return samples.first?.quantity.doubleValue(for: .degreeCelsius())
    }

    // MARK: - Quantity helpers

    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> Double? {
        let type = HKObjectType.quantityType(forIdentifier: identifier)!
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error {
                    // "No data in window" is a normal state, not a failure —
                    // mirror the same coercion the other helpers do.
                    if Self.isNoData(error) { cont.resume(returning: nil); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: (samples as? [HKQuantitySample])?.first)
            }
            store.execute(q)
        }
        return sample?.quantity.doubleValue(for: unit)
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> Double? {
        let type = HKObjectType.quantityType(forIdentifier: identifier)!
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error {
                    if Self.isNoData(error) { cont.resume(returning: nil); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    // MARK: - VO2max

    func vo2maxSamples(days: Int = 180) async throws -> [VO2maxTrajectory.Sample] {
        let type = HKObjectType.quantityType(forIdentifier: .vo2Max)!
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]) { _, samples, error in
                if let error {
                    if Self.isNoData(error) { cont.resume(returning: []); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        let unit = HKUnit(from: "ml/kg*min")
        return samples.map { VO2maxTrajectory.Sample(date: $0.endDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    // MARK: - Body composition (height / weight → BMI)

    struct BodyComposition: Sendable {
        let heightMeters: Double?
        let weightKg: Double?

        var bmi: Double? {
            guard let h = heightMeters, let w = weightKg, h > 0 else { return nil }
            return w / (h * h)
        }
    }

    /// Latest height and body mass. Height is effectively static (look back
    /// years); weight uses the most recent entry within a year. Resilient: any
    /// missing/denied type collapses to nil rather than failing the refresh.
    func bodyComposition() async -> BodyComposition {
        let end = Date()
        let heightInterval = DateInterval(start: Calendar.current.date(byAdding: .year, value: -10, to: end)!, end: end)
        let weightInterval = DateInterval(start: Calendar.current.date(byAdding: .day, value: -365, to: end)!, end: end)
        async let h = try? latestQuantity(.height, unit: .meter(), in: heightInterval)
        async let w = try? latestQuantity(.bodyMass, unit: .gramUnit(with: .kilo), in: weightInterval)
        return BodyComposition(heightMeters: (await h) ?? nil, weightKg: (await w) ?? nil)
    }

    /// Athlete's age in whole years from the HealthKit date-of-birth
    /// characteristic. Feeds Tanaka HRmax (208 − 0.7·age) and the VO₂max bands.
    /// nil when DOB isn't shared or auth is denied — callers fall back gracefully.
    func ageInYears(calendar: Calendar = .current) -> Int? {
        guard let components = try? store.dateOfBirthComponents(),
              let birthDate = calendar.date(from: components) else { return nil }
        let years = calendar.dateComponents([.year], from: birthDate, to: Date()).year
        guard let years, years > 0, years < 120 else { return nil }
        return years
    }

    /// Biological sex from HealthKit, mapped to the TRIMP weighting selector.
    /// nil when not shared or set to "other"/unspecified — TRIMP then defaults
    /// to the male curve (its historical behavior).
    func biologicalSex() -> AthleteSex? {
        guard let sex = try? store.biologicalSex().biologicalSex else { return nil }
        switch sex {
        case .female: return .female
        case .male:   return .male
        default:      return nil
        }
    }

    // MARK: - Workouts

    func workouts(in interval: DateInterval) async throws -> [WorkoutSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    if Self.isNoData(error) { cont.resume(returning: []); return }
                    cont.resume(throwing: error); return
                }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        return workouts.map { w in
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            let distance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter())
            let hrStats = w.statistics(for: HKQuantityType(.heartRate))
            let bpmUnit = HKUnit(from: "count/min")
            let avgHR = hrStats?.averageQuantity()?.doubleValue(for: bpmUnit)
            let maxHR = hrStats?.maximumQuantity()?.doubleValue(for: bpmUnit)
            let elevation = (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
            return WorkoutSummary(
                id: w.uuid,
                kind: kind(for: w.workoutActivityType),
                start: w.startDate,
                end: w.endDate,
                activeEnergyKcal: energy,
                averageHeartRate: avgHR,
                maxHeartRate: maxHR,
                distanceMeters: distance,
                elevationAscendedMeters: elevation
            )
        }
    }

    private func kind(for type: HKWorkoutActivityType) -> WorkoutSummary.Kind {
        switch type {
        case .running: return .run
        case .walking, .hiking: return .walk
        case .traditionalStrengthTraining, .functionalStrengthTraining, .crossTraining: return .lift
        case .cycling: return .ride
        default: return .other
        }
    }

    // MARK: - Diagnostics

    struct DiagnosticReport: Equatable {
        struct TypeStatus: Identifiable, Equatable {
            let id = UUID()
            let label: String
            let sampleCount: Int
            let lastSampleAt: Date?
            let lastValue: String?
            let notes: String?
        }
        let generatedAt: Date
        let windowDays: Int
        let types: [TypeStatus]
    }

    /// Runs a sample query for every metric the app cares about over the last `days`
    /// and reports raw counts + the most recent sample. Use this to figure out *why*
    /// a sub-score is empty (auth denied / no data / unexpected sample type).
    func diagnostics(days: Int = 7) async -> DiagnosticReport {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
        let interval = DateInterval(start: start, end: end)

        var results: [DiagnosticReport.TypeStatus] = []

        // Sleep — break down by stage so we can see whether stages are present at all.
        results.append(await diagnoseSleep(interval: interval))
        results.append(await diagnoseQuantity(.heartRateVariabilitySDNN, label: "HRV (SDNN)", unit: HKUnit.secondUnit(with: .milli), unitSuffix: " ms", interval: interval))
        results.append(await diagnoseQuantity(.restingHeartRate, label: "Resting HR", unit: HKUnit(from: "count/min"), unitSuffix: " bpm", interval: interval))
        results.append(await diagnoseQuantity(.heartRate, label: "Heart rate (any)", unit: HKUnit(from: "count/min"), unitSuffix: " bpm", interval: interval))
        if let _ = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            results.append(await diagnoseQuantity(.appleSleepingWristTemperature, label: "Wrist temperature (sleeping)", unit: .degreeCelsius(), unitSuffix: " °C", interval: interval))
        }
        results.append(await diagnoseQuantity(.respiratoryRate, label: "Respiratory rate", unit: HKUnit(from: "count/min"), unitSuffix: " brpm", interval: interval))
        results.append(await diagnoseQuantity(.stepCount, label: "Steps", unit: .count(), unitSuffix: "", interval: interval))
        results.append(await diagnoseQuantity(.activeEnergyBurned, label: "Active energy", unit: .kilocalorie(), unitSuffix: " kcal", interval: interval))
        results.append(await diagnoseWorkouts(interval: interval))

        return DiagnosticReport(generatedAt: end, windowDays: days, types: results)
    }

    private func diagnoseSleep(interval: DateInterval) async -> DiagnosticReport.TypeStatus {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        do {
            let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
                let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                    if let error {
                        if Self.isNoData(error) { cont.resume(returning: []); return }
                        cont.resume(throwing: error); return
                    }
                    cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
                }
                store.execute(q)
            }
            var stageBreakdown: [String: Int] = [:]
            for s in samples {
                let label: String
                switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                case .inBed: label = "inBed"
                case .awake: label = "awake"
                case .asleepUnspecified: label = "asleep"
                case .asleepCore: label = "core"
                case .asleepDeep: label = "deep"
                case .asleepREM: label = "REM"
                default: label = "other"
                }
                stageBreakdown[label, default: 0] += 1
            }
            let breakdownText = stageBreakdown.isEmpty
                ? nil
                : stageBreakdown.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: " · ")
            return .init(
                label: "Sleep analysis",
                sampleCount: samples.count,
                lastSampleAt: samples.map(\.endDate).max(),
                lastValue: nil,
                notes: breakdownText ?? (samples.isEmpty ? "No sleep samples in window — either auth denied, or the watch never wrote any sessions." : nil)
            )
        } catch {
            return .init(label: "Sleep analysis", sampleCount: 0, lastSampleAt: nil, lastValue: nil, notes: "Error: \(error.localizedDescription)")
        }
    }

    private func diagnoseQuantity(_ id: HKQuantityTypeIdentifier, label: String, unit: HKUnit, unitSuffix: String, interval: DateInterval) async -> DiagnosticReport.TypeStatus {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else {
            return .init(label: label, sampleCount: 0, lastSampleAt: nil, lastValue: nil, notes: "Type unavailable on this iOS version")
        }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        do {
            let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
                let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                    if let error {
                        if Self.isNoData(error) { cont.resume(returning: []); return }
                        cont.resume(throwing: error); return
                    }
                    cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
                store.execute(q)
            }
            let latest = samples.first
            let lastValue = latest.map { String(format: "%.1f%@", $0.quantity.doubleValue(for: unit), unitSuffix) }
            let note: String? = samples.isEmpty
                ? "No samples in window — either auth denied for this type, or the watch doesn't measure it."
                : nil
            return .init(label: label, sampleCount: samples.count, lastSampleAt: latest?.endDate, lastValue: lastValue, notes: note)
        } catch {
            return .init(label: label, sampleCount: 0, lastSampleAt: nil, lastValue: nil, notes: "Error: \(error.localizedDescription)")
        }
    }

    private func diagnoseWorkouts(interval: DateInterval) async -> DiagnosticReport.TypeStatus {
        do {
            let ws = try await workouts(in: interval)
            let breakdown = Dictionary(grouping: ws, by: \.kind).mapValues(\.count)
            let breakdownText = breakdown.isEmpty
                ? nil
                : breakdown.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { "\($0.key.rawValue): \($0.value)" }.joined(separator: " · ")
            return .init(
                label: "Workouts",
                sampleCount: ws.count,
                lastSampleAt: ws.map(\.end).max(),
                lastValue: nil,
                notes: breakdownText
            )
        } catch {
            return .init(label: "Workouts", sampleCount: 0, lastSampleAt: nil, lastValue: nil, notes: "Error: \(error.localizedDescription)")
        }
    }

    /// Run an async operation that may throw; fold any error (including the
    /// transient HealthKit ones we can't anticipate) down to nil. Used by every
    /// per-day query so a single failure can't cascade and erase the rest of
    /// that day's signals.
    private func tolerant<T>(_ operation: @Sendable () async throws -> T?) async -> T? {
        do {
            return try await operation()
        } catch {
            return nil
        }
    }

    /// HealthKit raises `HKError.noData` when a predicate window contains zero samples.
    /// For us that's a normal "user didn't wear the watch / metric not supported" state,
    /// not a failure — collapse it into an empty result.
    static func isNoData(_ error: Error) -> Bool {
        // HKErrorNoData = 11. Use the raw code to stay stable across SDK renames.
        let ns = error as NSError
        return ns.domain == HKErrorDomain && ns.code == 11
    }

    // Simple training load proxy: kcal × (avgHR factor). Replace with TRIMP when ready.
    private func load(for w: WorkoutSummary) -> Double {
        let hrFactor: Double = {
            guard let hr = w.averageHeartRate else { return 1.0 }
            return max(0.5, min(2.0, hr / 130.0))
        }()
        return w.activeEnergyKcal * hrFactor
    }
}
