import Foundation

/// A Darwin notification posted after every write to the shared store, by the app and by the
/// widget extension alike. The app listens for it to re-plan its notifications: an extension
/// can't schedule or cancel local notifications itself (e.g. the widget's checkbox).
public enum StoreChangeSignal {
    public static let name = "lueddemann.howy.store-changed"

    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }
}
