import Foundation

/// The App Group shared by the Howy app and the HowyWidgets extension.
///
/// Must match `com.apple.security.application-groups` on both targets in `project.yml`.
public enum HowyAppGroup {
    /// The App Group identifier, e.g. for `containerURL(forSecurityApplicationGroupIdentifier:)`.
    public static let identifier = "group.howy"

    /// The shared container directory, or `nil` if the system refuses it.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
