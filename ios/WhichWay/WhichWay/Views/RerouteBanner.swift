import SwiftUI

/// The faster route on offer while a route is under way, as one step and the time it saves.
struct RerouteOffer {
    var faster: FasterRoute
    /// The route in hand's itinerary from where the rider is, for the side-by-side.
    var current: Itinerary?
    var currentOption: PathOption
    /// The rider is on a train: the first step is getting off it somewhere.
    var onTrain: Bool
}

/// "Off at Hoyt 10:42, then the C" on the train; "Take the E at 10:42" otherwise.
func rerouteStepText(_ o: RerouteOffer, name: (String) -> String) -> String {
    let it = o.faster.itinerary, p = o.faster.option
    let first = p.legs.count - it.legs.count
    guard let l0 = it.legs.first, p.legs.indices.contains(first) else { return "" }
    if o.onTrain {
        let off = "Off at \(name(p.legs[first].to)) \(Fmt.hhmm(l0.arriveTs))"
        if it.legs.count > 1 { return "\(off), then the \(it.legs[1].train.route) at \(Fmt.hhmm(it.legs[1].boardTs))" }
        return "Stay on to \(name(p.legs[first].to)), \(Fmt.hhmm(l0.arriveTs))"
    }
    return "Take the \(l0.train.route) at \(Fmt.hhmm(l0.boardTs)) from \(name(p.legs[first].from))"
}

/// The strip across the top of the Go tab: the faster route, how much sooner, a look at it side by side, and the
/// switch.
struct RerouteBanner: View {
    let offer: RerouteOffer
    let name: (String) -> String
    let onView: () -> Void
    let onSwitch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.title3.weight(.semibold)).foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.minTxt(offer.faster.savedSec)) sooner: \(offer.faster.option.label)")
                    .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(rerouteStepText(offer, name: name)) · in \(Fmt.hhmm(offer.faster.itinerary.arriveTs))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onView)
            Button("Switch", action: onSwitch)
                .font(.caption.weight(.semibold)).buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).accessibilityLabel("Keep my route")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}

/// The route in hand and the faster one side by side, from where the rider is: each train, where to get on and off,
/// and when each gets them in.
struct RerouteSheet: View {
    let offer: RerouteOffer
    let name: (String) -> String
    let onSwitch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(rerouteStepText(offer, name: name)).font(.headline)
                    Text("Gets you in at \(Fmt.hhmm(offer.faster.itinerary.arriveTs)), \(Fmt.minTxt(offer.faster.savedSec)) sooner than \(Fmt.hhmm(offer.faster.currentArriveTs)), from where you are now.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Faster: \(offer.faster.option.label)") { steps(offer.faster.itinerary, option: offer.faster.option) }
                Section("Your route: \(offer.currentOption.label)") {
                    if let c = offer.current { steps(c, option: offer.currentOption) } else { Text("No train in the feeds yet").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Faster route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep mine") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Switch") { onSwitch(); dismiss() }.bold() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One row per train still to ride: the line, where it is boarded (or "on board") and where the rider leaves it.
    private func steps(_ it: Itinerary, option p: PathOption) -> some View {
        let first = p.legs.count - it.legs.count
        return ForEach(Array(it.legs.enumerated()), id: \.offset) { j, l in
            let leg = p.legs.indices.contains(first + j) ? p.legs[first + j] : nil
            HStack(spacing: 10) {
                RouteBullet(route: l.train.route, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    if offer.onTrain && j == 0 {
                        Text("On board").font(.subheadline.weight(.semibold))
                    } else {
                        Text("\(Fmt.hhmm(l.boardTs)) from \(leg.map { name($0.from) } ?? "")").font(.subheadline.weight(.semibold))
                    }
                    Text("off at \(leg.map { name($0.to) } ?? "") \(Fmt.hhmm(l.arriveTs))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
