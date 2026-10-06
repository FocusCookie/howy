import Foundation

/// Which quadrant a new todo starts on in the quick-entry picker (a Settings choice).
public enum NewTodoQuadrant: Hashable, Sendable, CaseIterable, Identifiable {
    /// The quadrant the previous todo was created in.
    case lastUsed
    case fixed(Quadrant)

    public static let allCases: [NewTodoQuadrant] = [.lastUsed] + Quadrant.allCases.map(NewTodoQuadrant.fixed)

    /// 0 for last used, otherwise the quadrant's raw value.
    public var rawValue: Int {
        switch self {
        case .lastUsed: 0
        case .fixed(let quadrant): quadrant.rawValue
        }
    }

    public init(rawValue: Int) {
        self = Quadrant(rawValue: rawValue).map(NewTodoQuadrant.fixed) ?? .lastUsed
    }

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .lastUsed: "Last Used"
        case .fixed(let quadrant): quadrant.displayName
        }
    }

    /// The picker's starting quadrant given the remembered last-used one.
    public func resolve(lastUsed: Quadrant?) -> Quadrant {
        switch self {
        case .lastUsed: lastUsed ?? .urgentImportant
        case .fixed(let quadrant): quadrant
        }
    }

    public static let defaultsKey = "newTodoQuadrant"

    /// The stored setting; `.lastUsed` when unset.
    public static func load(from defaults: UserDefaults = .standard) -> NewTodoQuadrant {
        NewTodoQuadrant(rawValue: defaults.integer(forKey: defaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
