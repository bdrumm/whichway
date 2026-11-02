import SwiftUI

/// Settings, Commute outlook: the switch (off until the rider turns it on), how long before the usual leaving time
/// the notification comes, whether learned trips are notified too, and the trips expected today and tomorrow.
struct OutlookSection: View {
    @Environment(DataService.self) private var data
    @Environment(PresetStore.self) private var presets
    private var outlook: OutlookService { OutlookService.shared }

    var body: some View {
        Section {
            Toggle("Notify before my trips", isOn: Binding(get: { outlook.settings.enabled }, set: { on in
                Task { await outlook.setEnabled(on, presets: presets.presets, data: data) }
            }))
            if outlook.denied {
                Text("Notifications are off for WhichWay. Allow them in the iPhone's Settings, Notifications, WhichWay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if outlook.settings.enabled {
                Stepper("\(outlook.settings.leadMinutes) min before I usually leave", value: Binding(get: { outlook.settings.leadMinutes }, set: { m in
                    Task { await outlook.setLeadMinutes(m, presets: presets.presets, data: data) }
                }), in: 0...60, step: 5)
                Toggle("Trips learned from my rides", isOn: Binding(get: { outlook.settings.learnedTrips }, set: { on in
                    Task { await outlook.setLearnedTrips(on, presets: presets.presets, data: data) }
                }))
            }
            if outlook.upcoming.isEmpty {
                Text("No trips expected today or tomorrow yet. Saved commutes show here on their days; trips you repeat show once you have made them on three days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(outlook.upcoming) { t in OutlookRow(trip: t, scheduled: outlook.scheduled.contains { $0.id == OutlookNotifications.idPrefix + t.id }) }
        } header: {
            Text("Commute outlook")
        } footer: {
            Text("Your expected trips come from your saved commutes and the trips you have ridden, which stay on the phone. The notification says when you usually leave, your usual way and how long it usually takes at that hour.")
        }
        .task { await outlook.refresh(presets: presets.presets, data: data) }
    }
}

struct OutlookRow: View {
    @Environment(DataService.self) private var data
    let trip: OutlookTrip
    let scheduled: Bool

    private func name(_ id: String) -> String { id.isEmpty ? "Nearest station" : (data.index?.station(id)?.name ?? id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(Fmt.dayStamp(trip.leaveTs) == Fmt.dayStamp(data.now) ? "Today" : "Tomorrow") \(Fmt.hhmm(trip.leaveTs))").font(.subheadline.bold())
                Text("\(name(trip.origin)) → \(name(trip.dest))").font(.subheadline).lineLimit(1)
                Spacer()
                if scheduled { Image(systemName: "bell.fill").font(.caption).foregroundStyle(.secondary) }
            }
            Text([trip.likelihoodText, trip.route?.text, "usually \(Fmt.hhmm(trip.earlyTs))–\(Fmt.hhmm(trip.lateTs))"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
