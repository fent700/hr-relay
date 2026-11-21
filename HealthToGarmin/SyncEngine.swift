import Foundation
import HealthKit
import UserNotifications

struct LedgerEntry: Codable, Identifiable {
    enum Status: String, Codable {
        case uploaded, duplicate, skippedGarminSource, failed
        var label: String {
            switch self {
            case .uploaded: return "Uploaded"
            case .duplicate: return "Already in Garmin"
            case .skippedGarminSource: return "Came from Garmin"
            case .failed: return "Failed (will retry)"
            }
        }
    }
    let id: String            // HealthKit workout UUID
    var status: Status
    var workoutStart: Date
    var name: String
    var detail: String
    var updatedAt: Date
}

struct SyncReport {
    var uploaded = 0, duplicates = 0, skipped = 0, failed = 0
    var message: String?
    var summary: String {
        if let message { return message }
        if uploaded + duplicates + skipped + failed == 0 { return "Up to date." }
        return "Uploaded \(uploaded) · already in Garmin \(duplicates) · skipped \(skipped) · failed \(failed)"
    }
}

/// Duplicate protection, in layers:
///  1. A persistent ledger of every HealthKit workout UUID already handled.
///  2. Workouts written to Apple Health *by* Garmin Connect are never sent back.
///  3. Before uploading, Garmin's activity list is checked for an activity that
///     starts within 3 minutes or overlaps by more than half (e.g. you wore both watches).
///  4. Garmin's own duplicate rejection (HTTP 409) is treated as "already there".
///  5. Only one sync can run at a time, so a foreground tap and a background
///     wake-up can't both upload the same workout.
actor SyncEngine {
    static let shared = SyncEngine()

    private var running = false
    private var entries: [String: LedgerEntry]
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("ledger.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: LedgerEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func recentEntries(limit: Int = 50) -> [LedgerEntry] {
        Array(entries.values.sorted { $0.workoutStart > $1.workoutStart }.prefix(limit))
    }

    func sync() async -> SyncReport {
        guard !running else { return SyncReport(message: "A sync is already running.") }
        running = true
        defer { running = false }

        guard await GarminClient.shared.isLoggedIn else { return SyncReport(message: "Sign in to Garmin first.") }

        let workouts: [HKWorkout]
        do {
            workouts = try await HealthKitManager.shared.workouts(since: Settings.syncStartDate)
        } catch {
            return SyncReport(message: "Couldn't read Health: \(error.localizedDescription)")
        }

        let pending = workouts.filter { w in
            guard let e = entries[w.uuid.uuidString] else { return true }
            return e.status == .failed
        }
        guard let first = pending.first, let last = pending.last else { return SyncReport() }

        var garmin: [GarminActivity]
        do {
            garmin = try await GarminClient.shared.activities(from: first.startDate, to: last.endDate)
        } catch {
            return SyncReport(message: "Couldn't check Garmin for duplicates, nothing uploaded: \(error.localizedDescription)")
        }

        var report = SyncReport()
        for w in pending {
            if Task.isCancelled { break }
            let name = w.workoutActivityType.displayName

            if w.sourceRevision.source.bundleIdentifier.lowercased().contains("garmin") {
                record(w, .skippedGarminSource, "Written to Health by Garmin Connect")
                report.skipped += 1
                continue
            }
            if let match = garmin.first(where: { Self.isSameActivity($0, w) }) {
                record(w, .duplicate, "Matches Garmin activity \(match.id)")
                report.duplicates += 1
                continue
            }
            do {
                let tcx = await TCXBuilder.build(for: w)
                let filename = "\(name)-\(Int(w.startDate.timeIntervalSince1970)).tcx"
                switch try await GarminClient.shared.upload(file: tcx, filename: filename) {
                case .uploaded(let id):
                    record(w, .uploaded, id.map { "Garmin activity \($0)" } ?? "Uploaded")
                    garmin.append(GarminActivity(id: id ?? 0, start: w.startDate, duration: w.duration))
                    report.uploaded += 1
                case .duplicate:
                    record(w, .duplicate, "Garmin reported a duplicate")
                    report.duplicates += 1
                }
            } catch {
                record(w, .failed, error.localizedDescription)
                report.failed += 1
            }
        }

        if report.uploaded > 0 { notify(report) }
        return report
    }

    static func isSameActivity(_ g: GarminActivity, _ w: HKWorkout) -> Bool {
        if abs(g.start.timeIntervalSince(w.startDate)) <= 180 { return true }
        let gEnd = g.start.addingTimeInterval(max(g.duration, 1))
        let overlap = min(gEnd, w.endDate).timeIntervalSince(max(g.start, w.startDate))
        let shorter = min(max(g.duration, 1), max(w.endDate.timeIntervalSince(w.startDate), 1))
        return overlap > 0.5 * shorter
    }

    private func record(_ w: HKWorkout, _ status: LedgerEntry.Status, _ detail: String) {
        entries[w.uuid.uuidString] = LedgerEntry(id: w.uuid.uuidString, status: status,
                                                 workoutStart: w.startDate,
                                                 name: w.workoutActivityType.displayName,
                                                 detail: detail, updatedAt: Date())
        // Saved after every workout so a crash mid-sync can't cause a re-upload.
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func notify(_ report: SyncReport) {
        let content = UNMutableNotificationContent()
        content.title = "Sent to Garmin Connect"
        content.body = report.uploaded == 1 ? "1 workout uploaded." : "\(report.uploaded) workouts uploaded."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
