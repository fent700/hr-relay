import Foundation
import HealthKit
import CoreLocation

final class HealthKitManager {
    static let shared = HealthKitManager()
    let store = HKHealthStore()
    private var observerStarted = false
    private let lock = NSLock()

    private var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.distanceWheelchair),
            HKQuantityType(.distanceDownhillSnowSports),
        ]
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthToGarmin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Health data isn't available on this device."])
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Wakes the app (even in the background) whenever a workout is added to Health.
    func startObserving() {
        lock.lock()
        let alreadyStarted = observerStarted
        observerStarted = true
        lock.unlock()

        if !alreadyStarted {
            let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    _ = await SyncEngine.shared.sync()
                    completion()
                }
            }
            store.execute(query)
        }
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { _, _ in }
    }

    func workouts(since start: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try await descriptor.result(for: store)
    }

    func heartRates(for workout: HKWorkout) async throws -> [(date: Date, bpm: Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())
        return try await descriptor.result(for: store).map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
    }

    func locations(for workout: HKWorkout) async throws -> [CLLocation] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HKSeriesType.workoutRoute(), predicate: predicate)],
            sortDescriptors: []
        )
        let routes = try await descriptor.result(for: store).compactMap { $0 as? HKWorkoutRoute }

        var all: [CLLocation] = []
        for route in routes {
            let locs: [CLLocation] = try await withCheckedThrowingContinuation { cont in
                var buffer: [CLLocation] = []
                var finished = false
                let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    if finished { return }
                    if let error { finished = true; cont.resume(throwing: error); return }
                    buffer.append(contentsOf: locations ?? [])
                    if done { finished = true; cont.resume(returning: buffer) }
                }
                store.execute(query)
            }
            all.append(contentsOf: locs)
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    func totalDistanceMeters(_ w: HKWorkout) -> Double {
        let ids: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                                               .distanceWheelchair, .distanceDownhillSnowSports]
        for id in ids {
            if let q = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                return q.doubleValue(for: .meter())
            }
        }
        return w.totalDistance?.doubleValue(for: .meter()) ?? 0
    }

    func activeKilocalories(_ w: HKWorkout) -> Double {
        if let q = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            return q.doubleValue(for: .kilocalorie())
        }
        return w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
    }
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Ride"
        case .hiking: return "Hike"
        case .swimming: return "Swim"
        case .rowing: return "Row"
        case .elliptical: return "Elliptical"
        case .stairClimbing, .stairs: return "Stairs"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .crossTraining: return "Cross Training"
        case .coreTraining: return "Core"
        case .dance, .cardioDance, .socialDance: return "Dance"
        case .snowboarding: return "Snowboard"
        case .downhillSkiing: return "Ski"
        case .crossCountrySkiing: return "XC Ski"
        case .tennis: return "Tennis"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .golf: return "Golf"
        case .paddleSports: return "Paddle"
        case .surfingSports: return "Surf"
        case .climbing: return "Climb"
        case .mixedCardio: return "Cardio"
        case .cooldown: return "Cooldown"
        default: return "Workout"
        }
    }

    /// TCX only knows three sports. Garmin lets you change the type afterward.
    var tcxSport: String {
        switch self {
        case .running: return "Running"
        case .cycling, .handCycling: return "Biking"
        default: return "Other"
        }
    }
}
