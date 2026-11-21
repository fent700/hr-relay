import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var garminLoggedIn = false
    @Published var needsMFA = false
    @Published var busy = false
    @Published var status = ""
    @Published var entries: [LedgerEntry] = []
    @Published var syncStart: Date = Settings.syncStartDate {
        didSet { Settings.syncStartDate = syncStart }
    }

    func refresh() async {
        garminLoggedIn = await GarminClient.shared.isLoggedIn
        entries = await SyncEngine.shared.recentEntries()
    }

    func connectHealth() async {
        do {
            try await HealthKitManager.shared.requestAuthorization()
            HealthKitManager.shared.startObserving()
            status = "Health access set. New workouts will sync automatically."
        } catch {
            status = error.localizedDescription
        }
    }

    func login(email: String, password: String) async {
        await run {
            switch try await GarminClient.shared.login(email: email, password: password) {
            case .success: self.status = "Signed in to Garmin."
            case .needsMFA: self.needsMFA = true; self.status = "Enter the code Garmin sent you."
            }
        }
    }

    func submitMFA(_ code: String) async {
        await run {
            try await GarminClient.shared.submitMFA(code: code)
            self.needsMFA = false
            self.status = "Signed in to Garmin."
        }
    }

    func syncNow() async {
        // Keep the screen on so iOS doesn't suspend a long backfill.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        await run {
            let report = await SyncEngine.shared.sync { done, total in
                Task { @MainActor in self.status = "Working on \(done) of \(total)…" }
            }
            self.status = report.summary
        }
    }

    func logout() async {
        await GarminClient.shared.logout()
        await refresh()
        status = "Signed out."
    }

    private func run(_ work: @MainActor @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work() } catch { status = error.localizedDescription }
        await refresh()
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var mfaCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Health") {
                    Button("Allow Health access") { Task { await model.connectHealth() } }
                }

                Section("Garmin Connect") {
                    if model.garminLoggedIn {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Sign out", role: .destructive) { Task { await model.logout() } }
                    } else if model.needsMFA {
                        TextField("Verification code", text: $mfaCode)
                            .keyboardType(.numberPad)
                        Button("Verify") { Task { await model.submitMFA(mfaCode) } }
                            .disabled(mfaCode.isEmpty || model.busy)
                    } else {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button("Sign in") {
                            Task {
                                await model.login(email: email, password: password)
                                password = ""
                            }
                        }
                        .disabled(email.isEmpty || password.isEmpty || model.busy)
                    }
                }

                Section {
                    DatePicker("Export workouts since", selection: $model.syncStart, displayedComponents: .date)
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync now")
                            if model.busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.busy || !model.garminLoggedIn)
                    if !model.status.isEmpty {
                        Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Syncs automatically when Apple Health gets a new workout. To upload old workouts, pick an earlier date and tap Sync now; keep the app open until it finishes. Workouts already in Garmin Connect are skipped.")
                }

                Section("History") {
                    if model.entries.isEmpty {
                        Text("Nothing synced yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.name).bold()
                                Spacer()
                                Text(e.workoutStart, format: .dateTime.month().day().hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                            Text(e.status.label)
                                .font(.caption)
                                .foregroundStyle(e.status == .failed ? .red : .secondary)
                            if e.status == .failed {
                                Text(e.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Health → Garmin")
            .task { await model.refresh() }
            .refreshable { await model.syncNow() }
        }
    }
}
