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
/// - KVS has a value: that value, known at once, and copied to the local cache (marked as
///   coming from the cloud);
/// - KVS has none: the retention is **unknown**, and nothing is purged, until KVS reports a
///   change (`cloudChanged`, which adopts the value it brings) or `decisionDelay` (24 hours)
///   has passed since the first time it was unknown (`tick`; remembered across launches, so
///   a Mac that is relaunched every day still decides). Then the local value counts, and only a
///   value the user chose on this Mac (`isExplicit`) seeds KVS. A Mac with no choice of its own
///   runs on the default and writes nothing, so it can never overwrite another Mac's choice.
///
/// Settings changes go to both (`set`).
@MainActor
@Observable
public final class ArchiveRetentionStore {
    /// How long to wait for KVS to bring a value before the local one counts: a fresh Mac's
    /// first KVS download can take long (or the other Mac hasn't uploaded yet).
    public static let decisionDelay: TimeInterval = 24 * 60 * 60

    public private(set) var retention: ArchiveRetention
    public private(set) var isKnown: Bool
    /// When an undecided store decides on its own (`tick`); `nil` once known.
    public private(set) var decisionDeadline: Date?

    @ObservationIgnored private let local: any KeyValueStoring
    @ObservationIgnored private let cloud: (any KeyValueStoring)?

    private static let key = ArchiveRetention.defaultsKey
    /// Local marker: the local value was copied from KVS, not chosen here.
    private static let fromCloudKey = ArchiveRetention.defaultsKey + ".fromCloud"
    /// Local marker: when the value first was unknown (seconds since 1970).
    private static let unknownSinceKey = ArchiveRetention.defaultsKey + ".unknownSince"

    public init(local: any KeyValueStoring, cloud: (any KeyValueStoring)?, now: Date) {
        self.local = local
        self.cloud = cloud
        retention = Self.value(in: local) ?? .default
        if cloud == nil {
            isKnown = true
        } else if let shared = Self.value(in: cloud) {
            isKnown = true
            retention = shared
            adopt(shared)
        } else {
            isKnown = false
            let since = (local.object(forKey: Self.unknownSinceKey) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? now
            // A clock that went back must not push the deadline out for ever.
            let first = min(since, now)
            local.set(first.timeIntervalSince1970, forKey: Self.unknownSinceKey)
            decisionDeadline = first.addingTimeInterval(Self.decisionDelay)
        }
    }

    /// Whether the value in use was chosen on this Mac (Settings), as far as it can tell: a
    /// local value that wasn't copied from KVS. Only such a value may seed KVS.
    public var isExplicit: Bool {
        Self.value(in: local) != nil && (local.object(forKey: Self.fromCloudKey) as? Bool) != true
    }

    /// KVS changed from outside (another Mac, the first download, an account change): adopt its
    /// value if it has one.
    public func cloudChanged() {
        guard let shared = Self.value(in: cloud) else { return }
        retention = shared
        adopt(shared)
        isKnown = true
        decisionDeadline = nil
    }

    /// Decides once `decisionDeadline` has passed: the local value counts, and seeds KVS only if
    /// the user chose it on this Mac. Returns whether that made the value known.
    @discardableResult
    public func tick(now: Date) -> Bool {
        guard !isKnown, let deadline = decisionDeadline, now >= deadline else { return false }
        if let shared = Self.value(in: cloud) {
            retention = shared
            adopt(shared)
        } else if isExplicit, let own = Self.value(in: local) {
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
        local.set(false, forKey: Self.fromCloudKey)
        cloud?.set(retention.days, forKey: Self.key)
        isKnown = true
        decisionDeadline = nil
    }

    /// Copies a value from KVS into the local cache and marks it as not chosen here.
    private func adopt(_ shared: ArchiveRetention) {
        local.set(shared.days, forKey: Self.key)
        local.set(true, forKey: Self.fromCloudKey)
    }

    /// A positive number of days stored under the key, else `nil`.
    private static func value(in store: (any KeyValueStoring)?) -> ArchiveRetention? {
        guard let number = store?.object(forKey: key) as? NSNumber else { return nil }
        let days = number.intValue
        return days > 0 ? ArchiveRetention(days: days) : nil
    }
}
