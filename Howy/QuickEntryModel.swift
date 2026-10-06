import Foundation
import HowyCore
import Observation
import SwiftUI

/// Glue between the quick-entry / edit panel, `QuickEntryFlow` and `TodoStore`.
/// Rules (keys, delete prompt, empty-title hint) live in the flow; this only performs the I/O
/// the flow asks for and reports failures instead of closing over them.
@MainActor
@Observable
final class QuickEntryModel {
    let flow: QuickEntryFlow
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}

    /// Set when saving or deleting failed; the panel stays open so nothing typed is lost.
    private(set) var errorMessage: String?

    init(flow: QuickEntryFlow, store: TodoStore) {
        self.flow = flow
        self.store = store
    }

    /// Returns `true` when the key was consumed.
    func handle(_ key: QuickEntryKey) -> Bool {
        let consumed = flow.handle(key)
        finishIfNeeded()
        return consumed
    }

    func save() {
        flow.save()
        finishIfNeeded()
    }

    func requestDelete() { flow.requestDelete() }
    func cancelDelete() { flow.cancelDelete() }

    func confirmDelete() {
        flow.confirmDelete()
        finishIfNeeded()
    }

    private func finishIfNeeded() {
        switch flow.phase {
        case .saved:
            if persist() { close() } else { flow.reopen() }
        case .deleted:
            if deleteTodo() { close() } else { flow.reopen() }
        case .cancelled:
            close()
        default:
            break
        }
    }

    private func persist() -> Bool {
        guard let draft = flow.savedDraft else { return true }
        do {
            if let id = draft.todoID {
                try store.update(id: id, title: draft.title, note: draft.note, quadrant: draft.quadrant)
            } else {
                try store.add(title: draft.title, note: draft.note, quadrant: draft.quadrant)
            }
            errorMessage = nil
            return true
        } catch {
            log.error("Save failed: \(error, privacy: .public)")
            errorMessage = "Couldn't save. Your text is still here."
            return false
        }
    }

    private func deleteTodo() -> Bool {
        guard let id = flow.todoID else { return true }
        do {
            try store.delete(id: id)
            errorMessage = nil
            return true
        } catch {
            log.error("Delete failed: \(error, privacy: .public)")
            errorMessage = "Couldn't delete this todo."
            return false
        }
    }
}

/// Archived todos for the archive panel, reloaded after every action.
@MainActor
@Observable
final class ArchiveModel {
    struct Item: Identifiable, Hashable {
        let id: UUID
        let title: String
        let quadrant: Quadrant
        let completedAt: Date
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}

    init(store: TodoStore) {
        self.store = store
        reload()
    }

    func restore(_ item: Item) {
        do { try store.restore(id: item.id) } catch { log.error("Restore failed: \(error, privacy: .public)") }
        reload()
    }

    func delete(_ item: Item) {
        do { try store.delete(id: item.id) } catch { log.error("Delete failed: \(error, privacy: .public)") }
        reload()
    }

    private func reload() {
        do {
            items = try store.archivedTodos().map {
                Item(id: $0.id, title: $0.title, quadrant: $0.quadrant, completedAt: $0.completedAt ?? .now)
            }
        } catch {
            log.error("Archive fetch failed: \(error, privacy: .public)")
            items = []
        }
    }
}

/// Glue between the browse panel, `BrowseFlow` and `TodoStore`: performs the opens,
/// completions and reorders the flow asks for.
@MainActor
@Observable
final class BrowseModel {
    let flow: BrowseFlow
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}
    /// Opens a todo in the edit modal (replaces this panel).
    @ObservationIgnored var openTodo: (UUID) -> Void = { _ in }

    private(set) var errorMessage: String?

    init(flow: BrowseFlow, store: TodoStore) {
        self.flow = flow
        self.store = store
    }

    /// Returns `true` when the key was consumed.
    func handle(_ key: QuickEntryKey) -> Bool {
        var outcome = BrowseFlow.Outcome.ignored
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.handle(key) }
        return perform(outcome)
    }

    func choose(_ quadrant: Quadrant) {
        withAnimation(.snappy(duration: 0.25)) { flow.choose(quadrant) }
    }

    func open(_ id: UUID) {
        flow.select(id: id)
        openTodo(id)
    }

    func complete(_ id: UUID) {
        var removed = false
        withAnimation(.snappy(duration: 0.25)) { removed = flow.complete(id: id) }
        if removed { persistCompletion(id) }
    }

    func select(_ id: UUID) {
        flow.select(id: id)
    }

    /// Moves a row while it is dragged; the order is written once the drag ends (`persistOrder`).
    func drag(_ id: UUID, to index: Int) {
        withAnimation(.snappy(duration: 0.2)) { _ = flow.move(id: id, to: index) }
    }

    /// Writes the shown list's current order.
    func persistOrder() {
        persistOrder(of: flow.quadrant)
    }

    private func perform(_ outcome: BrowseFlow.Outcome) -> Bool {
        switch outcome {
        case .ignored: return false
        case .handled: return true
        case .open(let id): openTodo(id)
        case .complete(let id): persistCompletion(id)
        case .reorder(let quadrant): persistOrder(of: quadrant)
        case .close: close()
        }
        return true
    }

    private func persistOrder(of quadrant: Quadrant) {
        do {
            try store.reorder(flow.rows.map(\.id), in: quadrant)
            errorMessage = nil
        } catch {
            log.error("Reorder failed: \(error, privacy: .public)")
            errorMessage = "Couldn't save the new order."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }

    private func persistCompletion(_ id: UUID) {
        do {
            try store.complete(id: id)
            errorMessage = nil
        } catch {
            log.error("Complete failed: \(error, privacy: .public)")
            errorMessage = "Couldn't mark this todo done."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }
}
