import AppKit
import UserNotifications

/// Notification Center banners for tickets: "your turn" when the agent has answered, and a reminder on the
/// day something is due. Clicking one opens that ticket in the Tickets window.
@MainActor
final class TicketNotifier: NSObject, UNUserNotificationCenterDelegate {
    private unowned let plugin: TicketsPlugin
    private var scheduled = false
    private var askedOnce = false
    private static let duePrefix = "tickets.due."

    init(plugin: TicketsPlugin) { self.plugin = plugin }

    /// Nil when the app runs outside its bundle (a debug build started from the terminal): there is no Notification Center for it.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app" ? nil : UNUserNotificationCenter.current()
    }

    func activate() {
        center?.delegate = self
        reschedule()
    }

    func deactivate() {
        guard let center else { return }
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(Self.duePrefix) })
        }
    }

    /// Asks for permission the first time something is about to be shown.
    private func authorized(_ then: @escaping @MainActor (UNUserNotificationCenter) -> Void) {
        guard let center else { return }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Task { @MainActor in then(center) }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Task { @MainActor in then(center) } }
                }
            default:
                Task { @MainActor in
                    guard !self.askedOnce else { return }
                    self.askedOnce = true
                    Toast.show("Ticket notifications are off for Quick Capture in System Settings → Notifications.", symbol: "bell.slash", isError: true)
                }
            }
        }
    }

    private func content(_ ticket: Ticket, subtitle: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let icon = plugin.store.structure.kinds.first { $0.id == ticket.kind }?.icon ?? ""
        content.title = (icon.isEmpty ? "" : icon + " ") + ticket.title
        let project = plugin.store.structure.projects.first { $0.id == ticket.project }?.name
        content.subtitle = [subtitle, project].compactMap { $0 }.joined(separator: " · ")
        content.body = body
        content.sound = .default
        content.threadIdentifier = "tickets"
        content.userInfo = ["ticket": ticket.id]
        return content
    }

    /// Markdown reads badly in a banner: keep the words.
    static func plain(_ text: String, limit: Int = 220) -> String {
        var out = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "[#*_`>|]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return out.count > limit ? String(out.prefix(limit)) + "…" : out
    }

    /// The agent answered (or its run failed) and the ticket now waits for the user.
    func yourTurn(_ id: Int, text: String, failed: Bool = false) {
        guard plugin.settings.notifyYourTurn, let ticket = plugin.store.tickets[id], ticket.mergedInto == nil else { return }
        // Already looking at the window: the reply is on screen.
        if NSApp.isActive, plugin.isWindowKey { return }
        let request = UNNotificationRequest(identifier: "tickets.turn.\(id)",
                                            content: content(ticket, subtitle: failed ? "The agent stopped" : "Your turn", body: Self.plain(text)), trigger: nil)
        authorized { $0.add(request) }
    }

    /// Re-plans every due reminder from the tickets as they are now. Cheap, so it runs after any change.
    func reschedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let center = self.center else { return }
            let settings = self.plugin.settings
            let plan = settings.notifyDue
                ? TicketReminders.plan(Array(self.plugin.store.tickets.values), now: Date(), hour: settings.dueNotifyHour, leadHours: settings.dueLeadHours) : []
            var requests: [UNNotificationRequest] = []
            for item in plan.prefix(50) {
                guard let ticket = self.plugin.store.tickets[item.ticket] else { continue }
                let when = DateFormatter.localizedString(from: item.due, dateStyle: .none, timeStyle: .short)
                let body = ticket.summary.isEmpty ? Self.plain(ticket.messages.first?.text ?? "", limit: 160) : ticket.summary
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fire)
                requests.append(UNNotificationRequest(
                    identifier: Self.duePrefix + "\(ticket.id)",
                    content: self.content(ticket, subtitle: item.timed ? "Due at \(when)" : "Due today", body: body),
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
            center.getPendingNotificationRequests { pending in
                center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.duePrefix) })
                guard !requests.isEmpty else { return }
                Task { @MainActor in self.authorized { center in requests.forEach { center.add($0) } } }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app is a menu-bar app and usually "in front" of nothing: show the banner anyway.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["ticket"] as? NSNumber)?.intValue
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.plugin.showWindow(ticket: id)
        }
        completionHandler()
    }
}
