import Foundation
import Observation

/// A key-value store: `UserDefaults`, `NSUbiquitousKeyValueStore`, or a test double.
public protocol KeyValueStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStoring {}
extension NSUbiquitousKeyValueStore: KeyValueStoring {}

/// The archive retention, shared through the iCloud key-value store (KVS), with this Mac's
/// `UserDefaults` as the cache and the fallback.
///
/// It must be one value everywhere: the Mac with the shortest retention would otherwise purge
/// archived todos on every Mac. So the purge waits until the value is *known* (`isKnown`):
///
/// - no KVS (`cloud == nil`, e.g. `synchronize()` failed): the local value, known at once;
/// - KVS has a value: that value, known at once, and copied to the local cache;
/// - KVS has none yet: the local value is shown, but it isn't known until KVS reports a change
///   (`cloudChanged`, which adopts the value it brings) or `decisionDelay` passes (`tick`). Then
///   the local value counts; if it was set on this Mac (the key exists locally), it seeds KVS,
///   so a Mac that has a choice hands it on, and a fresh Mac never overwrites another's with the
///   default.
///
/// Settings changes go to both (`set`).
@MainActor
@Observable
public final class ArchiveRetentionStore {
    /// How long to wait for KVS to bring a value before the local one counts.
    public static let decisionDelay: TimeInterval = 60

    public private(set) var retention: ArchiveRetention
    public private(set) var isKnown: Bool
    /// When an undecided store decides on its own (`tick`); `nil` once known.
    public private(set) var decisionDeadline: Date?

    @ObservationIgnored private let local: any KeyValueStoring
    @ObservationIgnored private let cloud: (any KeyValueStoring)?

    private static let key = ArchiveRetention.defaultsKey

    public init(local: any KeyValueStoring, cloud: (any KeyValueStoring)?, now: Date) {
        self.local = local
        self.cloud = cloud
        retention = Self.value(in: local) ?? .default
        if cloud == nil {
            isKnown = true
        } else if let shared = Self.value(in: cloud) {
            isKnown = true
            retention = shared
            local.set(shared.days, forKey: Self.key)
        } else {
            isKnown = false
            decisionDeadline = now.addingTimeInterval(Self.decisionDelay)
        }
    }

    /// KVS changed from outside (another Mac, the first download, an account change): adopt its
    /// value if it has one.
    public func cloudChanged() {
        guard let shared = Self.value(in: cloud) else { return }
        retention = shared
        local.set(shared.days, forKey: Self.key)
        isKnown = true
        decisionDeadline = nil
    }

    /// Decides once `decisionDeadline` has passed: the local value counts, and seeds KVS if it
    /// was set on this Mac. Returns whether that made the value known.
    @discardableResult
    public func tick(now: Date) -> Bool {
        guard !isKnown, let deadline = decisionDeadline, now >= deadline else { return false }
        if let shared = Self.value(in: cloud) {
            retention = shared
            local.set(shared.days, forKey: Self.key)
        } else if let own = Self.value(in: local) {
            retention = own
            cloud?.set(own.days, forKey: Self.key)
        }
        isKnown = true
        decisionDeadline = nil
        return true
    }

    /// A choice in Settings: saved locally and shared.
    public func set(_ retention: ArchiveRetention) {
        self.retention = retention
        local.set(retention.days, forKey: Self.key)
        cloud?.set(retention.days, forKey: Self.key)
        isKnown = true
        decisionDeadline = nil
    }

    /// A positive number of days stored under the key, else `nil`.
    private static func value(in store: (any KeyValueStoring)?) -> ArchiveRetention? {
        guard let number = store?.object(forKey: key) as? NSNumber else { return nil }
        let days = number.intValue
        return days > 0 ? ArchiveRetention(days: days) : nil
    }
}
