import CoreBluetooth
import CoreLocation
import Foundation
import HealthKit
import UIKit
import WatchConnectivity

/// Takes Apple Watch heart rate and re-broadcasts it as a standard BLE Heart
/// Rate sensor (service 0x180D) that a Garmin Edge pairs with like a chest strap.
///
/// Primary source: the HR Relay watch app, which sends each reading over
/// WatchConnectivity. Fallback: HealthKit on the phone, which on watchOS 8 only
/// gets the workout's samples after it ends.
///
/// Everything runs on the main queue. Nothing here is hot enough to need more.
final class RelayEngine: NSObject, ObservableObject {
    static let shared = RelayEngine()

    // MARK: Published state

    @Published private(set) var running = false
    @Published private(set) var bpm: Int?
    @Published private(set) var sampleDate: Date?
    @Published private(set) var sampleSource = ""
    @Published private(set) var bluetoothStatus = "Starting"
    @Published private(set) var advertising = false
    @Published private(set) var subscriberCount = 0
    @Published private(set) var healthStatus = "Not started"
    @Published private(set) var workoutStatus = "Off"
    @Published private(set) var watchStatus = "Checking"
    @Published private(set) var locationStatus = "Off"
    @Published private(set) var lockedDeliveries = 0
    @Published private(set) var notificationsSent = 0
    @Published private(set) var log: [String] = []

    // MARK: Tunables

    /// A watch sample older than this stops being broadcast. Gaps on the Garmin
    /// beat a fake flat line once the watch has genuinely gone quiet.
    static let holdWindow: TimeInterval = 120
    private static let lookback: TimeInterval = 600
    private static let pollAfterSilence: TimeInterval = 10
    private static let workoutRetryInterval = 60

    // MARK: Keys

    static let useWorkoutKey = "useWorkoutSession"
    static let useLocationKey = "useLocationKeepAlive"
    private static let runningKey = "relayRunning"
    private static let restoreID = "hrrelay.peripheral"

    // MARK: Bluetooth

    private static let hrServiceUUID = CBUUID(string: "180D")
    private static let hrMeasurementUUID = CBUUID(string: "2A37")
    private static let bodyLocationUUID = CBUUID(string: "2A38")
    private static let advertisedName = "HR Relay"

    private var peripheral: CBPeripheralManager!
    private var measurement: CBMutableCharacteristic?
    private var serviceAdded = false
    private var subscribers = Set<UUID>()

    // MARK: HealthKit

    private let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())
    private var anchoredQuery: HKAnchoredObjectQuery?
    private var observerQuery: HKObserverQuery?
    private var healthAuthorized = false
    private var lastDelivery = Date.distantPast
    private var workoutSession: HKWorkoutSession?
    private var lastWorkoutAttempt = 0
    /// The system ending the phone session repeatedly means it's losing to
    /// something (usually the watch's own workout). Stop fighting after three.
    private var workoutEnds = 0
    private static let maxWorkoutEnds = 3

    // MARK: Watch link

    private var lastWatchMessage = Date.distantPast
    private var watchAppInstalled: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isWatchAppInstalled
    }

    // MARK: Location keep-alive

    private let locationManager = CLLocationManager()
    private var backgroundActivity: CLBackgroundActivitySession?

    // MARK: Ticker

    private var ticker: DispatchSourceTimer?
    private var tick = 0

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            Self.useWorkoutKey: true,
            Self.useLocationKey: true,
        ])
        locationManager.delegate = self
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        // Created at launch, not on Start: a relaunch by Core Bluetooth state
        // restoration only hands the services back to a manager that exists.
        peripheral = CBPeripheralManager(delegate: self, queue: nil, options: [
            CBPeripheralManagerOptionShowPowerAlertKey: true,
            CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreID,
        ])
        if UserDefaults.standard.bool(forKey: Self.runningKey) {
            note("Resuming relay from last session")
            start()
        }
    }

    // MARK: Control

    func start() {
        guard !running else { return }
        running = true
        UserDefaults.standard.set(true, forKey: Self.runningKey)
        note("Relay started")

        startTicker()
        if peripheral.state == .poweredOn { publishService() }
        if UserDefaults.standard.bool(forKey: Self.useLocationKey) { startLocation() }

        guard HKHealthStore.isHealthDataAvailable() else {
            healthStatus = "Health unavailable on this device"
            return
        }
        healthStatus = "Requesting access"
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if let error {
                    self.healthStatus = "Access failed: \(error.localizedDescription)"
                    self.note("HealthKit authorization error: \(error.localizedDescription)")
                    return
                }
                self.healthAuthorized = ok
                self.healthStatus = ok ? "Waiting for watch samples" : "Access denied"
                guard ok else { return }
                self.startHeartRateQueries()
                self.workoutEnds = 0
                if self.watchAppInstalled {
                    self.launchWatchWorkout()
                } else if UserDefaults.standard.bool(forKey: Self.useWorkoutKey) {
                    self.startWorkoutSession()
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        UserDefaults.standard.set(false, forKey: Self.runningKey)

        ticker?.cancel()
        ticker = nil
        if WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable {
            WCSession.default.sendMessage(["cmd": "stop"], replyHandler: nil, errorHandler: nil)
        }
        stopHeartRateQueries()
        stopWorkoutSession()
        stopLocation()

        peripheral.stopAdvertising()
        peripheral.removeAllServices()
        serviceAdded = false
        measurement = nil
        subscribers.removeAll()
        subscriberCount = 0
        advertising = false

        healthStatus = "Stopped"
        note("Relay stopped")
    }

    /// Foreground return: the cheapest moment to repair anything that broke
    /// while locked, and the only moment advertising carries the full payload.
    func didBecomeActive() {
        guard running else { return }
        if anchoredQuery == nil, healthAuthorized { startHeartRateQueries() }
        if peripheral.state == .poweredOn {
            if !serviceAdded { publishService() } else { restartAdvertising() }
        }
        if UserDefaults.standard.bool(forKey: Self.useLocationKey), backgroundActivity == nil { startLocation() }
    }

    // MARK: HealthKit queries

    private func startHeartRateQueries() {
        stopHeartRateQueries()
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-Self.lookback), end: nil, options: [])

        let query = HKAnchoredObjectQuery(type: hrType, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, error in
            self?.ingest(samples, error: error, fromStream: true)
        }
        query.updateHandler = { [weak self] _, samples, _, _, error in
            self?.ingest(samples, error: error, fromStream: true)
        }
        store.execute(query)
        anchoredQuery = query

        // Wakes the app when Health gets new heart rate even if something else
        // let it suspend. Needs the background-delivery entitlement; without it
        // this logs an error and the anchored query carries on alone.
        let observer = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self] _, completion, error in
            if error == nil { DispatchQueue.main.async { self?.pollLatest() } }
            completion()
        }
        store.execute(observer)
        observerQuery = observer
        store.enableBackgroundDelivery(for: hrType, frequency: .immediate) { [weak self] ok, error in
            guard !ok else { return }
            DispatchQueue.main.async { self?.note("Background delivery unavailable: \(error?.localizedDescription ?? "unknown")") }
        }
    }

    private func stopHeartRateQueries() {
        if let anchoredQuery { store.stop(anchoredQuery) }
        if let observerQuery { store.stop(observerQuery) }
        anchoredQuery = nil
        observerQuery = nil
    }

    private func pollLatest() {
        guard running, healthAuthorized else { return }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-Self.lookback), end: nil, options: [])
        let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: 1, sortDescriptors: [newestFirst]) { [weak self] _, samples, error in
            self?.ingest(samples, error: error, fromStream: false)
        }
        store.execute(query)
    }

    private func ingest(_ samples: [HKSample]?, error: Error?, fromStream: Bool) {
        DispatchQueue.main.async { [self] in
            guard running else { return }
            if let error {
                let locked = (error as? HKError)?.code == .errorDatabaseInaccessible
                healthStatus = locked ? "Health locked, retrying" : "Query error: \(error.localizedDescription)"
                if fromStream {
                    // A long-running query that errored is dead. The ticker
                    // rebuilds it within five seconds.
                    if let anchoredQuery { store.stop(anchoredQuery) }
                    anchoredQuery = nil
                    note(locked ? "Health database locked; query will rebuild" : "Stream error: \(error.localizedDescription)")
                }
                return
            }
            let quantitySamples = (samples ?? []).compactMap { $0 as? HKQuantitySample }
            guard let newest = quantitySamples.max(by: { $0.endDate < $1.endDate }) else { return }
            lastDelivery = Date()
            if !UIApplication.shared.isProtectedDataAvailable { lockedDeliveries += 1 }
            if let sampleDate, newest.endDate <= sampleDate { return }

            bpm = Int(newest.quantity.doubleValue(for: bpmUnit).rounded())
            sampleDate = newest.endDate
            sampleSource = newest.sourceRevision.source.name
            healthStatus = "Receiving"
            broadcast()
        }
    }

    // MARK: Watch link

    /// Opens HR Relay on the watch and starts its workout, so one tap on the
    /// phone starts everything. Needs the watch awake and on the wrist.
    private func launchWatchWorkout() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .indoor
        store.startWatchApp(with: configuration) { [weak self] ok, error in
            DispatchQueue.main.async {
                self?.note(ok ? "Watch workout launched" : "Watch launch failed, start it on the watch: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    private func ingestWatch(bpm newBPM: Int, at date: Date) {
        guard running else { return }
        lastWatchMessage = Date()
        if !UIApplication.shared.isProtectedDataAvailable { lockedDeliveries += 1 }
        if watchStatus != "Live" { watchStatus = "Live" }
        if let sampleDate, date < sampleDate { return }
        bpm = newBPM
        sampleDate = date
        sampleSource = "watch app"
        broadcast()
    }

    private func refreshWatchStatus() {
        guard WCSession.isSupported() else { watchStatus = "Unsupported"; return }
        let link = WCSession.default
        if Date().timeIntervalSince(lastWatchMessage) < 15 {
            watchStatus = "Live"
        } else if link.activationState != .activated {
            watchStatus = "Connecting"
        } else if !link.isPaired {
            watchStatus = "No watch paired"
        } else if !link.isWatchAppInstalled {
            watchStatus = "App not installed"
        } else {
            watchStatus = running ? "Waiting for watch" : "Installed"
        }
    }

    // MARK: Workout session keep-alive

    /// An iPhone-side workout session keeps the app running with the screen
    /// locked. No builder is attached, so nothing is ever saved to Health and
    /// the watch's own workout stays the only record.
    private func startWorkoutSession() {
        guard running, workoutSession == nil else { return }
        lastWorkoutAttempt = tick
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        // Indoor: the session never asks for location, so it can't wake GPS.
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            session.delegate = self
            workoutSession = session
            session.startActivity(with: Date())
            workoutStatus = "Starting"
        } catch {
            workoutStatus = "Unavailable"
            note("Workout session failed: \(error.localizedDescription)")
        }
    }

    private func stopWorkoutSession() {
        workoutSession?.delegate = nil
        workoutSession?.end()
        workoutSession = nil
        workoutStatus = "Off"
    }

    // MARK: Location keep-alive

    /// Three-kilometre accuracy runs on cell and Wi-Fi, not GPS. The point is
    /// the background runtime it buys, not the fixes.
    private func startLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationStatus = "Requesting access"
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationStatus = "Denied"
        default:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
            if backgroundActivity == nil, UIApplication.shared.applicationState != .background {
                backgroundActivity = CLBackgroundActivitySession()
            }
            locationManager.startUpdatingLocation()
            locationStatus = "Active"
        }
    }

    private func stopLocation() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        locationStatus = "Off"
    }

    // MARK: Bluetooth

    private func publishService() {
        guard running, !serviceAdded else { return }
        let measurement = CBMutableCharacteristic(type: Self.hrMeasurementUUID, properties: [.notify], value: nil, permissions: [.readable])
        // 0x02 = wrist. Static values are served by Core Bluetooth itself.
        let location = CBMutableCharacteristic(type: Self.bodyLocationUUID, properties: [.read], value: Data([0x02]), permissions: [.readable])
        let service = CBMutableService(type: Self.hrServiceUUID, primary: true)
        service.characteristics = [measurement, location]
        self.measurement = measurement
        serviceAdded = true
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    private func restartAdvertising() {
        guard running, serviceAdded else { return }
        if peripheral.isAdvertising { peripheral.stopAdvertising() }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.hrServiceUUID],
            CBAdvertisementDataLocalNameKey: Self.advertisedName,
        ])
    }

    /// Standard Heart Rate Measurement: flags, then UINT8 (or UINT16) bpm.
    /// Flags 0x06 = contact supported + detected; 0x04 = supported, not detected.
    private func measurementPayload() -> Data? {
        guard let bpm, let sampleDate, Date().timeIntervalSince(sampleDate) <= Self.holdWindow else { return nil }
        if bpm > 255 {
            return Data([0x07, UInt8(bpm & 0xFF), UInt8(bpm >> 8)])
        }
        return Data([0x06, UInt8(max(bpm, 0))])
    }

    private func broadcast() {
        guard running, !subscribers.isEmpty, let measurement, let payload = measurementPayload() else { return }
        // false means the transmit queue is full. The next tick is one second
        // away, so a dropped notification is not worth queueing.
        if peripheral.updateValue(payload, for: measurement, onSubscribedCentrals: nil) {
            notificationsSent += 1
        }
    }

    // MARK: Ticker

    /// One heartbeat a second: the Garmin expects a sensor that talks at 1 Hz,
    /// and the same tick runs the watchdog that rebuilds whatever died.
    private func startTicker() {
        ticker?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.onTick() }
        timer.resume()
        ticker = timer
    }

    private func onTick() {
        guard running else { return }
        tick += 1
        broadcast()

        guard tick % 5 == 0 else { return }
        refreshWatchStatus()
        if healthAuthorized, anchoredQuery == nil { startHeartRateQueries() }
        if healthAuthorized, Date().timeIntervalSince(lastDelivery) > Self.pollAfterSilence { pollLatest() }
        if peripheral.state == .poweredOn {
            if !serviceAdded { publishService() } else if !peripheral.isAdvertising { restartAdvertising() }
        }
        if healthAuthorized,
           UserDefaults.standard.bool(forKey: Self.useWorkoutKey),
           workoutSession == nil,
           !watchAppInstalled,
           workoutEnds < Self.maxWorkoutEnds,
           tick - lastWorkoutAttempt >= Self.workoutRetryInterval {
            startWorkoutSession()
        }
    }

    // MARK: Log

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func note(_ message: String) {
        log.insert("\(Self.timeFormatter.string(from: Date()))  \(message)", at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension RelayEngine: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            bluetoothStatus = "On"
            if running {
                if serviceAdded, measurement != nil { restartAdvertising() } else { serviceAdded = false; publishService() }
            }
        case .poweredOff:
            bluetoothStatus = "Bluetooth is off"
            advertising = false
            serviceAdded = false
            subscribers.removeAll()
            subscriberCount = 0
        case .unauthorized:
            bluetoothStatus = "Bluetooth access denied"
        case .unsupported:
            bluetoothStatus = "Unsupported"
        case .resetting:
            bluetoothStatus = "Resetting"
            serviceAdded = false
        default:
            bluetoothStatus = "Unknown"
        }
        note("Bluetooth: \(bluetoothStatus)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        if let service = services.first(where: { $0.uuid == Self.hrServiceUUID }),
           let characteristic = service.characteristics?.first(where: { $0.uuid == Self.hrMeasurementUUID }) as? CBMutableCharacteristic {
            measurement = characteristic
            serviceAdded = true
            for central in characteristic.subscribedCentrals ?? [] { subscribers.insert(central.identifier) }
            subscriberCount = subscribers.count
            note("Bluetooth state restored, \(subscriberCount) subscriber(s)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            serviceAdded = false
            note("Publishing service failed: \(error.localizedDescription)")
            return
        }
        restartAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        advertising = error == nil
        note(error.map { "Advertising failed: \($0.localizedDescription)" } ?? "Advertising as \"\(Self.advertisedName)\"")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.hrMeasurementUUID else { return }
        subscribers.insert(central.identifier)
        subscriberCount = subscribers.count
        peripheral.setDesiredConnectionLatency(.low, for: central)
        note("Device subscribed (\(subscriberCount) connected)")
        broadcast()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.hrMeasurementUUID else { return }
        subscribers.remove(central.identifier)
        subscriberCount = subscribers.count
        note("Device unsubscribed (\(subscriberCount) connected)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == Self.hrMeasurementUUID, let payload = measurementPayload() {
            guard request.offset <= payload.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = payload.subdata(in: request.offset..<payload.count)
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension RelayEngine: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async { [self] in
            guard workoutSession === self.workoutSession else { return }
            switch toState {
            case .running:
                workoutStatus = "Active"
            case .ended, .stopped:
                self.workoutSession = nil
                workoutEnds += 1
                workoutStatus = workoutEnds < Self.maxWorkoutEnds ? "Ended, restarting" : "Ended by system"
                note("Workout session ended by the system (\(workoutEnds)/\(Self.maxWorkoutEnds))")
            default:
                workoutStatus = "Starting"
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard workoutSession === self.workoutSession else { return }
            self.workoutSession = nil
            workoutStatus = "Failed, retrying"
            note("Workout session error: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate

extension RelayEngine: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.refreshWatchStatus() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Fires when the phone switches to a different watch. The new pairing
    /// needs its own activation.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshWatchStatus() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let value = message["bpm"] as? Int else { return }
        let date = (message["t"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        DispatchQueue.main.async { self.ingestWatch(bpm: value, at: date) }
    }
}

// MARK: - CLLocationManagerDelegate

extension RelayEngine: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard running, UserDefaults.standard.bool(forKey: Self.useLocationKey) else { return }
        startLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            locationStatus = "Denied"
            note("Location denied; background runtime relies on the workout session")
        }
    }
}
