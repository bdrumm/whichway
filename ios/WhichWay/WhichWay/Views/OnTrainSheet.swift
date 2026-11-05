import SwiftUI

/// The rider's own word on the train they are on: every train at their station on every line and in both directions,
/// standing there, due, or gone in the last 25 minutes (nearest the moment first), each with the route it leads to,
/// and, with a change ahead, every line to take at it. Nothing is left off for being unlikely: this is the override
/// for when the phone's reading is wrong (`trainsToPick`). Used
/// to start a route from a train already boarded, to put a route right when the phone guessed wrong or never
/// felt the pull-away, and to redirect the rest of the trip.
struct OnTrainSheet: View {
    struct TransferChoice: Identifiable {
        var key: String
        var label: String
        var id: String { key }
    }
    let stationName: String
    let candidates: [BoardingCandidate]
    let currentTrainId: String?
    let routeFor: (String) -> String?
    let describe: (BoardingCandidate) -> String
    let transfer: (station: String, choices: [TransferChoice])?
    let riding: Bool
    let onPick: (BoardingCandidate) -> Void
    let onTransfer: (String) -> Void
    let onNotOnTrain: () -> Void
    /// A change short of the route's own that the train in hand has reached ("A/C at Jay St-MetroTech"), and taking it.
    var changedHere: String? = nil
    var onChangedHere: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    /// Where the train is against the station: gone, standing there, or due.
    private func when(_ c: BoardingCandidate) -> String {
        if (c.progressIdx ?? c.boardIdx) > c.boardIdx { return "Left \(stationName) about \(Fmt.hhmm(PlatformTiming.pullsAway(c.boardTs, route: c.route)))" }
        if c.stoppedAtBoardTs != nil { return "At \(stationName) now" }
        return "Due at \(stationName) \(Fmt.hhmm(PlatformTiming.atPlatform(c.boardTs, route: c.route)))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty {
                        Text("No train at \(stationName) in the feeds right now. Lines not on the list yet appear after the next refresh.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.trainId) { c in
                        Button { onPick(c); dismiss() } label: {
                            HStack(spacing: 10) {
                                RouteBullet(route: c.route, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(when(c)).font(.subheadline.weight(.semibold))
                                    Text(describe(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(routeFor(c.key) ?? "Off your route: the trip follows this train").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if c.trainId == currentTrainId { Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(Color.accentColor) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("I am on the \(c.route): \(when(c))")
                    }
                } header: {
                    Text("Which train are you on?")
                } footer: {
                    Text("The route follows the train you pick: the change ahead, the arrival and the Live Activity.")
                }
                if let here = changedHere {
                    Section {
                        Button { onChangedHere(); dismiss() } label: {
                            Label("I changed to the \(here)", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                        }
                    } footer: {
                        Text("The phone cannot feel a step across the platform. The route moves to the change you made and follows the train you took.")
                    }
                }
                if let t = transfer, !t.choices.isEmpty {
                    Section("At \(t.station), take the") {
                        ForEach(t.choices) { ch in
                            Button { onTransfer(ch.key); dismiss() } label: {
                                HStack(spacing: 10) {
                                    RouteBullet(route: String(ch.key.split(separator: "_").first ?? ""), size: 26)
                                    Text(ch.label.isEmpty ? "Off your route: the trip follows this line" : ch.label).font(.subheadline).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if riding {
                    Section {
                        Button("Not on a train", role: .destructive) { onNotOnTrain(); dismiss() }
                    }
                }
            }
            .navigationTitle("Your train")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
