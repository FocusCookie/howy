import CloudKit
import Foundation

/// The iCloud account as Howy's CloudKit container sees it (`CKContainer.accountStatus()` and,
/// when available, `userRecordID()`).
public enum AccountObservation: Hashable, Sendable {
    /// Signed in. `userRecordName` is the account's user record name in Howy's container (stable
    /// for one account, different for another); `nil` when it couldn't be fetched just now.
    case available(userRecordName: String?)
    /// No iCloud account on this Mac.
    case noAccount
    /// Signed in, but the user record can't be fetched because the user isn't authenticated for
    /// Howy (`notAuthenticated`): iCloud is off for Howy (or for this Mac's apps).
    case iCloudOffForApp
    /// Parental controls or device management don't allow iCloud.
    case restricted
    /// Signed in but not ready for CloudKit yet. Apple: don't delete cached data; wait for
    /// `CKAccountChanged`.
    case temporarilyUnavailable
    /// The status couldn't be read.
    case couldNotDetermine

    /// Whether this says the account is gone (as opposed to unknown just now).
    var isGone: Bool {
        switch self {
        case .noAccount, .iCloudOffForApp, .restricted: true
        case .available, .temporarilyUnavailable, .couldNotDetermine: false
        }
    }

    /// Reads the account from a container: the status, then the user record for `.available`.
    /// `CKAccountChanged` comes from a container instance, so the caller keeps one.
    public static func current(in container: CKContainer) async -> AccountObservation {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            return .couldNotDetermine
        }
        switch status {
        case .available:
            do {
                return .available(userRecordName: try await container.userRecordID().recordName)
            } catch let error as CKError where error.code == .notAuthenticated {
                return .iCloudOffForApp
            } catch {
                return .available(userRecordName: nil)
            }
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }
}

/// Tells a sign-out and an account switch apart from the account this Mac's store last mirrored
/// with, remembered outside the synced store (per Mac, per store file; `SyncMonitor` keeps it in
/// `UserDefaults`).
///
/// - First account seen (nothing remembered): remembered, nothing to report. This covers a Mac
///   that synced before Phase 3c and a fresh install.
/// - Same account: nothing.
/// - Another account: `.switched`, and the new one is remembered.
/// - No account, iCloud off for Howy, or restricted, while one was remembered: `.signedOut`,
///   and nothing is remembered any more, so signing back in (the data comes back) or into
///   another account later reports nothing: the wipe was reported already.
/// - Temporarily unavailable, unknown, or a user record that couldn't be fetched: nothing
///   changes (Apple: don't treat these as a sign-out).
///
/// Edge: a sign-out and a sign-in to another account while Howy wasn't running is reported as
/// `.switched` at the next launch; a sign-out and back into the same account while it wasn't
/// running isn't seen at all (mirroring downloads everything again).
public struct SyncAccountTracker: Hashable, Sendable {
    public private(set) var remembered: String?

    public init(remembered: String? = nil) {
        self.remembered = remembered
    }

    public mutating func observe(_ observation: AccountObservation) -> AccountChange? {
        switch observation {
        case .available(let name?):
            defer { remembered = name }
            guard let remembered, remembered != name else { return nil }
            return .switched
        case _ where observation.isGone:
            guard remembered != nil else { return nil }
            remembered = nil
            return .signedOut
        default:
            return nil
        }
    }
}
