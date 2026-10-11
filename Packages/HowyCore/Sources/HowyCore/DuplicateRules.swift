import Foundation

/// A row type whose `id` isn't unique in the store (schema v3 has no unique constraint, and with
/// CloudKit two rows with one id are two separate records).
///
/// `DuplicateKey` is every stored value except `id`; two rows with equal keys are *identical*.
/// `prefers(_:over:)` is a strict total order over keys: for keys that differ it always says
/// which one wins, from the values alone. Nothing device-local (fetch order,
/// `persistentModelID`) takes part, so every device with the same rows picks the same survivor.
protocol DuplicateResolvable: AnyObject {
    associatedtype DuplicateKey: Hashable
    var id: UUID { get }
    var duplicateKey: DuplicateKey { get }
    /// Whether a row with `a` wins over one with `b`. False both ways only when `a == b`.
    static func prefers(_ a: DuplicateKey, over b: DuplicateKey) -> Bool
}

/// The rules for rows that share an id, used by every read in `TodoStore` and by the cleanup in
/// `StoreMaintenance`, so what a read shows is always what the cleanup keeps.
///
/// - Identical rows (equal keys) are all kept: deleting one of them is unsafe across devices,
///   since each Mac could delete a different one and both records would be gone. Reads collapse
///   them to one, and writes keep them identical.
/// - Rows that differ resolve to the survivor (`DuplicateResolvable.prefers(_:over:)`); the
///   cleanup deletes every row whose values aren't the survivor's.
enum DuplicateRules {
    /// The winning row of rows that share an id. Among identical rows, any of them.
    static func survivor<Row: DuplicateResolvable>(of rows: [Row]) -> Row? {
        guard var best = rows.first else { return nil }
        for row in rows.dropFirst() where Row.prefers(row.duplicateKey, over: best.duplicateKey) {
            best = row
        }
        return best
    }

    /// One row per id, the survivor, in the order of `rows`. `rows` must hold every row of each
    /// id in it (a fetch without a predicate).
    static func collapsed<Row: DuplicateResolvable>(_ rows: [Row]) -> [Row] {
        let groups = Dictionary(grouping: rows, by: \.id)
        guard groups.count < rows.count else { return rows }
        let keep = Set(groups.values.compactMap { survivor(of: $0).map(ObjectIdentifier.init) })
        return rows.filter { keep.contains(ObjectIdentifier($0)) }
    }

    /// The rows the cleanup deletes: per id, every row whose values differ from the survivor's.
    /// Identical rows are never among them.
    static func losers<Row: DuplicateResolvable>(_ rows: [Row]) -> [Row] {
        var result: [Row] = []
        for group in Dictionary(grouping: rows, by: \.id).values where group.count > 1 {
            guard let key = survivor(of: group)?.duplicateKey else { continue }
            result += group.filter { $0.duplicateKey != key }
        }
        return result
    }

    /// The ids that occur more than once in `ids`.
    static func repeated(_ ids: [UUID]) -> Set<UUID> {
        var seen = Set<UUID>()
        var repeated = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            repeated.insert(id)
        }
        return repeated
    }

    /// A date at whole milliseconds. CloudKit keeps dates to the millisecond, so a row that made
    /// a round trip through it must still compare equal to the local original.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1000).rounded(.down))
    }

    static func milliseconds(_ date: Date?) -> Int64? {
        date.map(milliseconds)
    }

    /// Orders optionals: `nil` before any value.
    static func ascending<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
        switch (a, b) {
        case (nil, nil): nil
        case (nil, _): true
        case (_, nil): false
        case let (a?, b?): a == b ? nil : a < b
        }
    }
}

extension Todo: DuplicateResolvable {
    /// Every stored value but `id`, dates at millisecond precision.
    struct DuplicateKey: Hashable {
        var updatedAt: Int64
        var completedAt: Int64?
        var due: Int64?
        var note: String
        var sortDate: Int64
        var title: String
        var createdAt: Int64
        var quadrantRaw: Int
    }

    var duplicateKey: DuplicateKey {
        DuplicateKey(
            updatedAt: DuplicateRules.milliseconds(updatedAt),
            completedAt: DuplicateRules.milliseconds(completedAt),
            due: DuplicateRules.milliseconds(due),
            note: note,
            sortDate: DuplicateRules.milliseconds(sortDate),
            title: title,
            createdAt: DuplicateRules.milliseconds(createdAt),
            quadrantRaw: quadrantRaw
        )
    }

    /// Which of two rows with one id survives. In order, the first difference decides:
    /// 1. the newer `updatedAt` (the last write wins);
    /// 2. archived over open (a tick isn't lost);
    /// 3. with a due date over without;
    /// 4. the longer note;
    /// 5. the newer `sortDate`;
    /// 6. the greater title, then the greater note, by plain string order;
    /// 7. the later `completedAt`, then the later `due`, then the later `createdAt`;
    /// 8. the lower `quadrantRaw`.
    ///
    /// Steps 6–8 only make the order total over every stored value, so the choice never
    /// depends on anything but the values.
    static func prefers(_ a: DuplicateKey, over b: DuplicateKey) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if (a.completedAt != nil) != (b.completedAt != nil) { return a.completedAt != nil }
        if (a.due != nil) != (b.due != nil) { return a.due != nil }
        if a.note.count != b.note.count { return a.note.count > b.note.count }
        if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
        if a.title != b.title { return a.title > b.title }
        if a.note != b.note { return a.note > b.note }
        if let later = DuplicateRules.ascending(b.completedAt, a.completedAt) { return later }
        if let later = DuplicateRules.ascending(b.due, a.due) { return later }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.quadrantRaw < b.quadrantRaw
    }
}

extension TodoEvent: DuplicateResolvable {
    /// Every stored value but `id`, dates at millisecond precision.
    struct DuplicateKey: Hashable {
        var date: Int64
        var seq: Int
        var kindRaw: String
        var todoID: String
        var fromQuadrantRaw: Int?
        var toQuadrantRaw: Int?
        var previousDue: Int64?
        var due: Int64?
    }

    var duplicateKey: DuplicateKey {
        DuplicateKey(
            date: DuplicateRules.milliseconds(date),
            seq: seq,
            kindRaw: kindRaw,
            todoID: todoID.uuidString,
            fromQuadrantRaw: fromQuadrantRaw,
            toQuadrantRaw: toQuadrantRaw,
            previousDue: DuplicateRules.milliseconds(previousDue),
            due: DuplicateRules.milliseconds(due)
        )
    }

    /// Which of two events with one id survives: the earlier `date`, then the lower `seq`, then
    /// the lower `kindRaw`, `todoID` (as a string), `fromQuadrantRaw`, `toQuadrantRaw`,
    /// `previousDue` and `due`, each with `nil` first. A total order over every stored value.
    static func prefers(_ a: DuplicateKey, over b: DuplicateKey) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.seq != b.seq { return a.seq < b.seq }
        if a.kindRaw != b.kindRaw { return a.kindRaw < b.kindRaw }
        if a.todoID != b.todoID { return a.todoID < b.todoID }
        if let lower = DuplicateRules.ascending(a.fromQuadrantRaw, b.fromQuadrantRaw) { return lower }
        if let lower = DuplicateRules.ascending(a.toQuadrantRaw, b.toQuadrantRaw) { return lower }
        if let lower = DuplicateRules.ascending(a.previousDue, b.previousDue) { return lower }
        return DuplicateRules.ascending(a.due, b.due) ?? false
    }
}
