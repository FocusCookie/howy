import Foundation

/// A Darwin notification posted after every write to the shared store, by the app and by the
/// widget extension alike. The app listens for it to re-plan its notifications: an extension
/// can't schedule or cancel local notifications itself (e.g. the widget's checkbox).
///
/// A write from an app extension also posts `extensionName`, so the app can tell the widget's
/// writes from its own and refresh an open panel (its contexts don't see another process's
/// writes until they fetch again).
public enum StoreChangeSignal {
    public static let name = "lueddemann.howy.store-changed"
    /// Posted, besides `name`, when the writer is an app extension (the widget).
    public static let extensionName = "lueddemann.howy.store-changed-by-extension"

    public static func post() {
        post(name)
        if isAppExtension(Bundle.main.bundleURL) { post(extensionName) }
    }

    /// Whether a bundle at `url` is an app extension (`.appex`).
    static func isAppExtension(_ url: URL) -> Bool {
        url.pathExtension == "appex"
    }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }
}
