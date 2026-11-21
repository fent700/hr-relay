import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct HealthToGarminApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundSync.schedule() }
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Both must be set up at launch: iOS relaunches the app in the background
        // when HealthKit has a new workout, and the observer has to be live again.
        BackgroundSync.register()
        HealthKitManager.shared.startObserving()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return true
    }
}

enum BackgroundSync {
    static let identifier = "healthtogarmin.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task {
                _ = await SyncEngine.shared.sync()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Safety net in case a HealthKit background wake-up is missed.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

enum Settings {
    private static let key = "syncStartDate"

    /// Only workouts that start on/after this date are exported. Defaults to the
    /// day the app is first opened, so your whole history isn't dumped by surprise.
    static var syncStartDate: Date {
        get {
            if let d = UserDefaults.standard.object(forKey: key) as? Date { return d }
            let d = Calendar.current.startOfDay(for: Date())
            UserDefaults.standard.set(d, forKey: key)
            return d
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
