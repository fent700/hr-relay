import HealthKit
import SwiftUI
import WatchKit

/// The phone's Start button calls startWatchApp(with:), which lands here.
final class ExtensionDelegate: NSObject, WKExtensionDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchRelay.shared.start()
    }
}

@main
struct HRRelayWatchApp: App {
    @WKExtensionDelegateAdaptor(ExtensionDelegate.self) private var extensionDelegate
    @StateObject private var relay = WatchRelay.shared

    var body: some Scene {
        WindowGroup {
            WatchView().environmentObject(relay)
        }
    }
}

struct WatchView: View {
    @EnvironmentObject private var relay: WatchRelay

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(relay.bpm.map(String.init) ?? "--")
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .foregroundColor(relay.running ? .red : .gray)
                Text("BPM")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            Text(relay.phoneReachable ? "Phone linked" : "Phone not linked")
                .font(.footnote)
                .foregroundColor(relay.phoneReachable ? .green : .gray)
            Button(relay.running ? "Stop" : "Start") {
                relay.running ? relay.stop() : relay.start()
            }
            .tint(relay.running ? .gray : .red)
            Text(relay.status)
                .font(.caption2)
                .foregroundColor(.gray)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }
}
