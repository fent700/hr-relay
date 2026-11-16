import SwiftUI
import UIKit

@main
struct HRRelayApp: App {
    @StateObject private var engine = RelayEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.didBecomeActive() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: RelayEngine
    @AppStorage(RelayEngine.useWorkoutKey) private var useWorkout = true
    @AppStorage(RelayEngine.useLocationKey) private var useLocation = true
    @State private var pocketMode = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 18) {
                    readout
                    controlButton
                    statusCard
                    if engine.running {
                        Button {
                            pocketMode = true
                        } label: {
                            Label("Pocket mode", systemImage: "moon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    optionsCard
                    stepsCard
                    logCard
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())

            if pocketMode {
                PocketView { pocketMode = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pocketMode)
    }

    private var readout: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = engine.sampleDate.map { context.date.timeIntervalSince($0) }
            let fresh = (age ?? .infinity) <= RelayEngine.holdWindow
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(engine.bpm.map(String.init) ?? "--")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(fresh ? Color.red : Color.gray)
                    Text("BPM")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(ageText(age))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }

    private func ageText(_ age: TimeInterval?) -> String {
        guard let age else { return engine.running ? "Waiting for the watch" : "Relay off" }
        let seconds = max(0, Int(age))
        let source = engine.sampleSource.isEmpty ? "" : " from \(engine.sampleSource)"
        if seconds < 60 { return "\(seconds)s ago\(source)" }
        return "\(seconds / 60)m \(seconds % 60)s ago\(source)"
    }

    private var controlButton: some View {
        Button {
            engine.running ? engine.stop() : engine.start()
        } label: {
            Text(engine.running ? "Stop relay" : "Start relay")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.running ? .gray : .red)
        .controlSize(.large)
    }

    private var statusCard: some View {
        Card {
            StatusRow(name: "Bluetooth", value: engine.advertising ? "Broadcasting" : engine.bluetoothStatus, good: engine.advertising)
            StatusRow(name: "Connected devices", value: "\(engine.subscriberCount)", good: engine.subscriberCount > 0)
            StatusRow(name: "Health", value: engine.healthStatus, good: engine.healthStatus == "Receiving")
            StatusRow(name: "Workout keep-alive", value: engine.workoutStatus, good: engine.workoutStatus == "Active")
            StatusRow(name: "Location keep-alive", value: engine.locationStatus, good: engine.locationStatus == "Active")
            StatusRow(name: "Updates while locked", value: "\(engine.lockedDeliveries)", good: engine.lockedDeliveries > 0)
            StatusRow(name: "Notifications sent", value: "\(engine.notificationsSent)", good: engine.notificationsSent > 0)
        }
    }

    private var optionsCard: some View {
        Card {
            Toggle("Workout session keep-alive", isOn: $useWorkout)
            Toggle("Location keep-alive", isOn: $useLocation)
            Text("Changes apply the next time the relay starts. Leave both on for locked-phone rides.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(engine.running)
    }

    private var stepsCard: some View {
        Card {
            Text("Ride setup").font(.headline)
            Group {
                Text("1. Start the relay here and allow Health, Bluetooth and Location.")
                Text("2. On the watch, start an Outdoor Cycle workout in the Workout app.")
                Text("3. First time only: with this app open, pair the Edge with a new heart rate sensor named \"HR Relay\".")
                Text("4. Lock the phone and ride. If \"Updates while locked\" stays at 0 after a test, use Pocket mode instead.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var logCard: some View {
        Card {
            Text("Log").font(.headline)
            if engine.log.isEmpty {
                Text("Nothing yet").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(engine.log.prefix(25).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Black screen, minimum brightness, no auto-lock, proximity sensor on. In a
/// pocket the display switches off while the phone stays unlocked with the app
/// in front, so Health is never encrypted and advertising is never throttled.
struct PocketView: View {
    let onExit: () -> Void
    @EnvironmentObject private var engine: RelayEngine
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Text(engine.bpm.map(String.init) ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.22))
                Text("Hold anywhere to exit")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.16))
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1.2) { onExit() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isProximityMonitoringEnabled = true
        }
        .onDisappear {
            UIDevice.current.isProximityMonitoringEnabled = false
            UIApplication.shared.isIdleTimerDisabled = false
            UIScreen.main.brightness = savedBrightness
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StatusRow: View {
    let name: String
    let value: String
    let good: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(good ? Color.green : Color(white: 0.35))
                .frame(width: 8, height: 8)
            Text(name).font(.subheadline)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
