import Foundation
import HealthKit
import WatchConnectivity

/// Runs a workout session so the optical sensor reads continuously, and sends
/// every heart rate the live builder collects to the iPhone over
/// WatchConnectivity. That's the only live path from a Series 3, because
/// watchOS 8 doesn't sync workout samples to the phone's Health store until the
/// workout ends.
final class WatchRelay: NSObject, ObservableObject {
    static let shared = WatchRelay()

    @Published private(set) var running = false
    @Published private(set) var bpm: Int?
    @Published private(set) var phoneReachable = false
    @Published private(set) var status = "Ready"
    @Published private(set) var sent = 0

    private let store = HKHealthStore()
    private let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start() {
        guard !running else { return }
        running = true
        status = "Starting"
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                guard ok else {
                    self.running = false
                    self.status = error?.localizedDescription ?? "Health access denied"
                    return
                }
                self.beginWorkout()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        let finishing = builder
        session?.end()
        // Discarded: the Garmin owns the ride. A saved watch workout would
        // show up on Strava a second time through Apple Health.
        finishing?.endCollection(withEnd: Date()) { _, _ in finishing?.discardWorkout() }
        session = nil
        builder = nil
        status = "Stopped"
    }

    private func beginWorkout() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        // Indoor: no GPS on the watch or the phone. The Edge records the route.
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] ok, error in
                DispatchQueue.main.async {
                    self?.status = ok ? "Live" : "Sensor failed: \(error?.localizedDescription ?? "unknown")"
                }
            }
        } catch {
            running = false
            status = "Workout failed: \(error.localizedDescription)"
        }
    }

    private func send(bpm: Int, at date: Date) {
        let link = WCSession.default
        guard link.activationState == .activated else { return }
        // From the watch, sendMessage wakes the iPhone app in the background,
        // which is how the relay keeps getting data with the phone locked.
        link.sendMessage(["bpm": bpm, "t": date.timeIntervalSince1970], replyHandler: nil) { [weak self] error in
            DispatchQueue.main.async { self?.status = "Phone: \(error.localizedDescription)" }
        }
        sent += 1
        if status.hasPrefix("Phone:") { status = "Live" }
    }
}

extension WatchRelay: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(hrType),
              let statistics = workoutBuilder.statistics(for: hrType),
              let quantity = statistics.mostRecentQuantity() else { return }
        let value = Int(quantity.doubleValue(for: bpmUnit).rounded())
        let date = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        DispatchQueue.main.async { [self] in
            guard running else { return }
            bpm = value
            send(bpm: value, at: date)
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension WatchRelay: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        DispatchQueue.main.async { [self] in
            guard workoutSession === session else { return }
            running = false
            session = nil
            builder = nil
            status = "Workout ended"
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard workoutSession === session else { return }
            status = "Workout error: \(error.localizedDescription)"
        }
    }
}

extension WatchRelay: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.phoneReachable = session.isReachable }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.phoneReachable = session.isReachable }
    }

    /// The phone's Stop button ends the watch workout too.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["cmd"] as? String == "stop" else { return }
        DispatchQueue.main.async { self.stop() }
    }
}
