import Foundation
import Observation
import UserNotifications

/// The commute outlook on the phone: the trips the rider is expected to make today and tomorrow
/// (`CommuteOutlook`), and, once the rider turns it on, a local notification ahead of each (`OutlookNotifications`).
/// Off until the rider turns it on in Settings; while off, no notification is scheduled and nothing else changes.
/// Recomputed whenever the app comes to the foreground and when its settings change.
@MainActor
@Observable
final class OutlookService {
    static let shared = OutlookService()
    static let settingsKey = "outlookSettings"

    private(set) var settings: OutlookSettings
    /// The expected trips as last computed, today first.
    private(set) var upcoming: [OutlookTrip] = []
    /// The notifications as last scheduled.
    private(set) var scheduled: [OutlookAlert] = []
    /// The rider turned it on but notifications are not allowed for the app.
    private(set) var denied = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: OutlookService.settingsKey).flatMap { try? JSONDecoder().decode(OutlookSettings.self, from: $0) } ?? OutlookSettings()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: OutlookService.settingsKey) }
    }

    /// Turning it on asks for permission to notify; refused, it stays off and says so.
    func setEnabled(_ on: Bool, presets: [CommutePreset], data: DataService) async {
        if on {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            denied = !granted
            settings.enabled = granted
        } else {
            settings.enabled = false
            denied = false
        }
        save()
        await refresh(presets: presets, data: data)
    }

    func setLeadMinutes(_ m: Int, presets: [CommutePreset], data: DataService) async {
        settings.leadMinutes = min(60, max(0, m))
        save()
        await refresh(presets: presets, data: data)
    }

    func setLearnedTrips(_ on: Bool, presets: [CommutePreset], data: DataService) async {
        settings.learnedTrips = on
        save()
        await refresh(presets: presets, data: data)
    }

    /// Recomputes the expected trips and, when on, replaces the pending outlook notifications with the new plan.
    func refresh(presets: [CommutePreset], data: DataService) async {
        let now = data.now
        upcoming = CommuteOutlook.trips(rides: HabitStore.shared.routes.rides, presets: presets, now: now, days: 2)
        let names: (String) -> String? = { id in data.index?.station(id)?.name }
        let expected: (OutlookTrip) -> Double? = { t in
            guard let s = data.schedule, let ix = data.index else { return nil }
            return outlookExpectedSec(t, schedule: s, index: ix, lineSched: data.lineSched, holds: data.holds, deviations: data.deviations)
        }
        let plan = OutlookNotifications.plan(upcoming, settings: settings, now: now, names: names, expectedSec: expected)
        let center = UNUserNotificationCenter.current()
        if settings.enabled {
            let status = await center.notificationSettings().authorizationStatus
            denied = !(status == .authorized || status == .provisional || status == .ephemeral)
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(OutlookNotifications.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        scheduled = []
        guard settings.enabled, !denied else { return }
        for a in plan {
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = .default
            content.threadIdentifier = "outlook"
            content.userInfo = ["outlookOrigin": a.origin, "outlookDest": a.dest]
            // the rider's own clock may differ from New York's: a delay from now lands on the same moment either way
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, a.fireTs - now), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: a.id, content: content, trigger: trigger))
                scheduled.append(a)
            } catch {}
        }
    }
}
