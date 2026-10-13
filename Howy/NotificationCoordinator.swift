import AppKit
import HowyCore
import Observation
import UserNotifications

/// The app's side of due-date notifications: keeps `UNUserNotificationCenter`'s pending requests
/// in step with `NotificationPlan`, and handles the notification's actions as the center's
/// delegate (only an app, not the widget extension, can be that delegate or schedule requests).
///
/// A sync runs at launch, on wake, after every store write (the shared store posts
/// `StoreChangeSignal`, from the app and from the widget's checkbox alike) and on the daily timer.
/// Permission is asked for the first time a due date is set (`dueDateWasSet`), never at launch;
/// without it nothing is scheduled and everything else keeps working.
///
/// It also posts the sync notifications (`post(_:)` with a `SyncAlert` from `SyncMonitor`):
/// delivered right away, one per kind (a newer one replaces the older), and a click opens
/// Settings at the sync line. A sync notice about a problem asks for permission itself if nobody
/// has yet: it may say the todos were removed from this Mac, which shouldn't be lost for want of
/// a due date. The Low Power Mode note doesn't (`SyncAlert.asksForPermission`).
@MainActor
@Observable
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    /// The notification permission as last read (Settings shows a hint when it is `.denied`).
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    /// Opens a todo in the editor (a click on the notification itself).
    @ObservationIgnored private var openTodo: (UUID) -> Void = { _ in }
    /// Opens Settings at the sync line (a click on a sync notification).
    @ObservationIgnored private var openSyncSettings: () -> Void = {}
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsAnotherSync = false

    /// The due dates handed to the notification center so far (JSON `[DueKey]`), so a due date
    /// whose request is gone once its moment passed counts as shown (`NotificationPlan.shown`).
    private static let scheduledKey = "scheduledDueNotifications"
    /// How long a scheduled due date is remembered (the archive's longest retention).
    private static let recordDays = 90

    private override init() {}

    /// Becomes the center's delegate (must happen before launching finishes), registers the
    /// actions, listens for store changes and runs the first sync.
    func start(openTodo: @escaping (UUID) -> Void, openSyncSettings: @escaping () -> Void) {
        self.openTodo = openTodo
        self.openSyncSettings = openSyncSettings
        center.delegate = self
        registerCategory()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in NotificationCoordinator.shared.requestSync() }
            },
            StoreChangeSignal.name as CFString, nil, .deliverImmediately
        )
        requestSync(after: .zero)
    }

    /// The Done, Snooze 1 h and Tomorrow actions. Registered again when the default time changes,
    /// since the Tomorrow button names it.
    func registerCategory() {
        let time = DueTime.load()
        let category = UNNotificationCategory(
            identifier: NotificationPlan.categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: NotificationPlan.doneAction, title: "Done"),
                UNNotificationAction(identifier: NotificationPlan.snoozeAction, title: "Snooze 1 h"),
                UNNotificationAction(identifier: NotificationPlan.tomorrowAction, title: "Tomorrow \(time.text)"),
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    /// A due date was just set: the first time, ask for permission; then sync.
    func dueDateWasSet() {
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    log.error("Notification permission request failed: \(error, privacy: .public)")
                }
            }
            await refreshAuthorization()
            requestSync(after: .zero)
        }
    }

    /// Re-reads the permission (Settings opens).
    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Opens System Settings at Howy's notification settings.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "lueddemann.howy"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sync notices

    /// Posts a sync notice now (asking for permission first if it was never asked and the notice
    /// asks for it, `SyncAlert.asksForPermission`).
    func post(_ alert: SyncAlert) {
        log.notice("Sync notice: \(alert.title, privacy: .public)")
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined, alert.asksForPermission {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    log.error("Notification permission request failed: \(error, privacy: .public)")
                }
            }
            await refreshAuthorization()
            guard authorization == .authorized || authorization == .provisional else {
                log.notice("Sync notice not shown: notifications are off")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
            } catch {
                log.error("Posting a sync notice failed: \(error, privacy: .public)")
            }
        }
    }

    /// Removes a sync notice that no longer applies, delivered or still pending.
    func withdraw(_ alert: SyncAlert) {
        center.removeDeliveredNotifications(withIdentifiers: [alert.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [alert.identifier])
    }

    // MARK: Sync

    /// Syncs soon; several requests in a row (one write posts the signal once per process) make one sync.
    func requestSync(after delay: Duration = .milliseconds(300)) {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        guard !isSyncing else {
            needsAnotherSync = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if needsAnotherSync {
                needsAnotherSync = false
                requestSync()
            }
        }
        await refreshAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }
        let todos: [TodoSnapshot]
        do {
            todos = try TodoStore.shared(didWrite: nil).openDueSnapshots()
        } catch {
            log.error("Notification sync couldn't read the store: \(error, privacy: .public)")
            return
        }
        let now = Date()
        var pending: [String: Date] = [:]
        for request in await center.pendingNotificationRequests() where NotificationPlan.todoID(fromIdentifier: request.identifier) != nil {
            let due = (request.content.userInfo[NotificationPlan.dueKey] as? Double).map(Date.init(timeIntervalSince1970:))
            pending[request.identifier] = due ?? .distantPast
        }
        let scheduled = Self.loadScheduled()
        let shown = NotificationPlan.shown(scheduled: scheduled, pending: pending, now: now)
        let planned = NotificationPlan.requests(for: todos, now: now, shown: shown)
        let diff = NotificationPlan.diff(planned: planned, pending: pending)

        if !diff.remove.isEmpty { center.removePendingNotificationRequests(withIdentifiers: diff.remove) }
        var added: Set<DueKey> = []
        for request in diff.add {
            do {
                try await center.add(Self.notificationRequest(for: request))
                added.insert(request.key)
            } catch {
                log.error("Scheduling a notification failed: \(error, privacy: .public)")
            }
        }
        // Archived todos keep their entries, so restoring one that already notified doesn't notify
        // again; entries older than the longest archive retention go, so the record stays small.
        let cutoff = now.addingTimeInterval(-Double(Self.recordDays) * 24 * 60 * 60)
        Self.saveScheduled(scheduled.union(added).filter { $0.due > cutoff })
        let current = Set(todos.compactMap { todo in todo.due.map { DueKey(id: todo.id, due: $0) } })
        await removeStaleDelivered(current: current)
        if !diff.add.isEmpty || !diff.remove.isEmpty {
            log.info("Notifications: \(diff.add.count, privacy: .public) added, \(diff.remove.count, privacy: .public) removed")
        }
    }

    /// Takes shown notifications out of Notification Center once their todo is done, deleted or
    /// has another (or no) due date.
    private func removeStaleDelivered(current: Set<DueKey>) async {
        var stale: [String] = []
        for notification in await center.deliveredNotifications() {
            let request = notification.request
            guard let id = NotificationPlan.todoID(fromIdentifier: request.identifier) else { continue }
            let due = (request.content.userInfo[NotificationPlan.dueKey] as? Double).map(Date.init(timeIntervalSince1970:))
            if let due, current.contains(DueKey(id: id, due: due)) { continue }
            stale.append(request.identifier)
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    private static func notificationRequest(for request: NotificationRequest) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = NotificationPlan.categoryIdentifier
        content.userInfo = [
            NotificationPlan.todoIDKey: request.todoID.uuidString,
            NotificationPlan.dueKey: request.due.timeIntervalSince1970,
        ]
        // No trigger: delivered right away (an overdue todo that never notified).
        let trigger = request.fireDate.map { date in
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                repeats: false
            )
        }
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
    }

    private static func loadScheduled() -> Set<DueKey> {
        guard let data = UserDefaults.standard.data(forKey: scheduledKey),
              let keys = try? JSONDecoder().decode([DueKey].self, from: data)
        else { return [] }
        return Set(keys)
    }

    private static func saveScheduled(_ keys: Set<DueKey>) {
        guard let data = try? JSONEncoder().encode(Array(keys)) else { return }
        UserDefaults.standard.set(data, forKey: scheduledKey)
    }

    // MARK: Delegate

    /// Howy's panels may be in front: show the banner anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Plain values out of the (non-Sendable) response before hopping to the main actor.
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix(SyncAlert.identifierPrefix) {
            await showSyncSettings()
            return
        }
        guard let id = NotificationPlan.todoID(fromIdentifier: identifier) else { return }
        await handle(action: action, todoID: id)
    }

    private func showSyncSettings() {
        openSyncSettings()
    }

    private func handle(action: String, todoID id: UUID) {
        do {
            switch action {
            case UNNotificationDefaultActionIdentifier:
                openTodo(id)
                return
            case NotificationPlan.doneAction:
                try TodoStore.shared().complete(id: id)
            case NotificationPlan.snoozeAction:
                try TodoStore.shared().snooze(id: id, by: NotificationPlan.snoozeInterval)
            case NotificationPlan.tomorrowAction:
                try TodoStore.shared().snooze(id: id, until: NotificationPlan.tomorrow(at: DueTime.load(), now: Date()))
            default:
                return
            }
        } catch {
            log.error("Notification action \(action, privacy: .public) failed: \(error, privacy: .public)")
        }
        requestSync()
    }
}
