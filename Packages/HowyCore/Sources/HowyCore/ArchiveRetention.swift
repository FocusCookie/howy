import Foundation

/// How many days archived todos are kept before they're purged (a Settings choice).
public struct ArchiveRetention: Hashable, Identifiable, Sendable {
    public let days: Int

    public static let defaultsKey = "archiveRetentionDays"
    /// The choices Settings offers.
    public static let options = [1, 3, 7, 14, 30, 90].map(ArchiveRetention.init(days:))
    public static let `default` = ArchiveRetention(days: 7)

    public init(days: Int) {
        self.days = days
    }

    public var id: Int { days }

    public var interval: TimeInterval { TimeInterval(days) * 24 * 60 * 60 }

    /// "1 day", "7 days".
    public var displayName: String { days == 1 ? "1 day" : "\(days) days" }

    /// The stored setting; 7 days when unset or not a positive number.
    public static func load(from defaults: UserDefaults = .standard) -> ArchiveRetention {
        let days = defaults.integer(forKey: defaultsKey)
        return days > 0 ? ArchiveRetention(days: days) : .default
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(days, forKey: Self.defaultsKey)
    }
}
