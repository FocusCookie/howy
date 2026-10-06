import Foundation

/// The `howy://` URL contract between the widgets and the menu-bar app.
///
/// - `howy://edit/<UUID>` — open the edit modal for a todo
/// - `howy://quick-add` / `howy://quick-add/<1-4>` — open quick entry (optionally preselecting a quadrant)
/// - `howy://archive` — open the archive modal
public enum DeepLink: Hashable, Sendable {
    case edit(UUID)
    case quickAdd(Quadrant?)
    case archive

    public static let scheme = "howy"

    public var url: URL {
        let path: String
        switch self {
        case .edit(let id): path = "edit/\(id.uuidString)"
        case .quickAdd(let quadrant?): path = "quick-add/\(quadrant.rawValue)"
        case .quickAdd(nil): path = "quick-add"
        case .archive: path = "archive"
        }
        return URL(string: "\(Self.scheme)://\(path)")!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.count) {
        case ("edit", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .edit(id)
        case ("quick-add", 0):
            self = .quickAdd(nil)
        case ("quick-add", 1):
            guard let n = Int(parts[0]), let quadrant = Quadrant(shortcutNumber: n) else { return nil }
            self = .quickAdd(quadrant)
        case ("archive", 0):
            self = .archive
        default:
            return nil
        }
    }
}
