import SwiftUI

/// "What's happening?": the rider's report in one or two taps, pinned to the train or platform the app already knows.
/// The kinds on offer follow where the rider is (on a train, or waiting); a kind with a second question (how crowded,
/// what incident) asks it on the same sheet. Sent through the report queue, so no signal underground is fine.
struct ReportSheet: View {
    let context: ReportContext
    let onTrain: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var picked: ReportKind?
    @State private var done: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        RouteBullet(route: context.route, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(onTrain ? "On this train, near \(context.stopName)" : "At \(context.stopName)").font(.subheadline.weight(.semibold))
                            Text(dirText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let d = done {
                        Label("Sent: \(d). Thanks, other riders and the model see it within a minute.", systemImage: "checkmark.seal.fill")
                            .font(.subheadline).foregroundStyle(.green)
                    } else if let k = picked, !k.subs.isEmpty {
                        Text(k == .crowded ? "How crowded?" : k == .incident ? "What kind?" : "What happened?").font(.headline)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(k.subs, id: \.key) { s in tile(s.label, symbol: k.symbol) { send(k, s.key) } }
                        }
                        Button("Back") { picked = nil }.font(.subheadline)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(ReportKind.offered(onTrain: onTrain)) { k in
                                tile(k.label, symbol: k.symbol, tint: k == .allGood ? .green : .orange) { if k.subs.isEmpty { send(k, nil) } else { picked = k } }
                            }
                        }
                    }
                    Text("Reports are anonymous: the line, the stop and the time, never your location. Whichway checks each one against the live feeds, and they teach the delay model what riders see.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("What's happening?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done == nil ? "Cancel" : "Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var dirText: String {
        switch context.dir {
        case "N": return "\(context.route) northbound"
        case "S": return "\(context.route) southbound"
        default: return "\(context.route) train"
        }
    }

    private func tile(_ label: String, symbol: String, tint: Color = .orange, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                Text(label).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Report: \(label)")
    }

    private func send(_ k: ReportKind, _ sub: String?) {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let r = RiderReport(kind: k, sub: sub, context: context, ts: Date().timeIntervalSince1970, appBuild: build)
        ReportQueue.shared.submit(r, stopName: context.stopName)
        done = r.summary(stopName: context.stopName)
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); dismiss() }
    }
}
