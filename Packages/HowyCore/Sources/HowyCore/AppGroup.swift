import Foundation

/// The App Group shared by the Howy app and the HowyWidgets extension.
///
/// Team-prefixed form (`<TeamID>.<suffix>`), matching the entitlement
/// `$(TeamIdentifierPrefix)io.lichtwart.howy` on both targets. The `group.` form is
/// deliberately avoided: a free Personal Team cannot register it on recent macOS.
public enum HowyAppGroup {
    /// Info.plist key both targets carry: `$(TeamIdentifierPrefix)io.lichtwart.howy`, i.e. the same
    /// expansion as the entitlement, so code and entitlement can't drift when the team changes.
    public static let infoKey = "HowyAppGroup"
    /// Used only when the Info.plist key is missing or unexpanded (e.g. in tests). Must equal
    /// `DEVELOPMENT_TEAM` + `.` + the suffix in `project.yml`.
    public static let fallbackIdentifier = "GQ9M79TF33.io.lichtwart.howy"

    /// The full App Group identifier, e.g. for `containerURL(forSecurityApplicationGroupIdentifier:)`.
    public static let identifier = resolve(infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    /// Picks the Info.plist value if it looks like a real team-prefixed identifier, else the fallback.
    static func resolve(infoValue: String?) -> String {
        guard let value = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$("), !value.hasPrefix("group.")
        else { return fallbackIdentifier }
        return value
    }

    /// The shared container directory, or `nil` if the system refuses it.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
