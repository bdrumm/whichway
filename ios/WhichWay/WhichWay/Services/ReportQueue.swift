import Foundation

/// The rider's reports on their way to the relay: kept on the phone until the relay takes them (underground there is
/// often no signal), sent at once when there is, and again whenever the app comes to the front. A report the relay
/// refuses as malformed, or one over two days old (no longer news), is dropped. Nothing here touches the trips.
@MainActor
@Observable
final class ReportQueue {
    static let shared = ReportQueue()
    /// The Report button on the Go tab; on unless the rider switches it off.
    static let enabledKey = "riderReports"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey) }

    private(set) var pending: [RiderReport] = []
    /// The last few sent, newest first, with the stop's name, for Settings.
    private(set) var sent: [Sent] = []
    private(set) var lastError: String?
    @ObservationIgnored private var sending = false
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var names: [String: String] = [:]

    struct Sent: Codable, Identifiable { var id: String; var ts: Double; var summary: String }
    private struct Disk: Codable { var pending: [RiderReport]; var sent: [Sent]; var names: [String: String] }

    var configured: Bool { TripRelay.shared.configured }

    init() {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("WhichWay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("reports.json")
        if let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(Disk.self, from: data) {
            pending = d.pending; sent = d.sent; names = d.names
        }
    }

    func submit(_ r: RiderReport, stopName: String) {
        pending.append(r)
        names[r.id] = stopName
        save()
        Task { await flush() }
    }

    /// Sends what is waiting, oldest first; stops at the first failure that a later try could get past.
    func flush() async {
        guard !sending, configured else { return }
        sending = true
        defer { sending = false; save() }
        let now = Date().timeIntervalSince1970
        pending.removeAll { now - $0.ts > 2 * 86400 }
        let enc = JSONEncoder()
        while let r = pending.first {
            do {
                try await TripRelay.shared.put(.report, enc.encode(r))
                pending.removeFirst()
                sent.insert(Sent(id: r.id, ts: r.ts, summary: r.summary(stopName: names[r.id] ?? r.stop)), at: 0)
                names[r.id] = nil
                lastError = nil
            } catch let e as NSError where e.domain == "TripRelay" && e.code == 400 {
                pending.removeFirst()           // the relay will never take this one
                names[r.id] = nil
                lastError = e.localizedDescription
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        if sent.count > 20 { sent.removeLast(sent.count - 20) }
    }

    private func save() {
        let d = Disk(pending: pending, sent: sent, names: names)
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: file, options: .atomic) }
    }
}
