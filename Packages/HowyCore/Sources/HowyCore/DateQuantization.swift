import Foundation
import SwiftData

/// The one-time pass that rounds every stored date to whole milliseconds
/// (`Date.wholeMilliseconds`), for rows written before Phase 3a stored dates that way.
///
/// CloudKit keeps dates to the millisecond. A row uploaded with a sub-millisecond date could
/// come back (on another Mac) a millisecond off, depending on whether the conversion rounds or
/// truncates, and then no longer compare identical to its twin (`DuplicateRules`). So the
/// shared store is quantized once before it first mirrors (`TodoStore.makeContainer`).
///
/// Only dates change; `updatedAt` isn't bumped (nothing the user did) and no events are recorded.
enum DateQuantization {
    /// Rounds the dates of every `Todo` and `TodoEvent` row in `context`'s store that aren't whole
    /// milliseconds yet, and saves. Returns the number of rows changed (0: nothing written).
    @discardableResult
    static func run(in context: ModelContext) throws -> Int {
        var changed = 0
        for todo in try context.fetch(FetchDescriptor<Todo>()) {
            var touched = false
            quantize(&todo.createdAt, &touched)
            quantize(&todo.sortDate, &touched)
            quantize(&todo.updatedAt, &touched)
            quantize(&todo.completedAt, &touched)
            quantize(&todo.due, &touched)
            if touched { changed += 1 }
        }
        for event in try context.fetch(FetchDescriptor<TodoEvent>()) {
            var touched = false
            quantize(&event.date, &touched)
            quantize(&event.previousDue, &touched)
            quantize(&event.due, &touched)
            if touched { changed += 1 }
        }
        guard changed > 0 else { return 0 }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return changed
    }

    private static func quantize(_ date: inout Date, _ touched: inout Bool) {
        let whole = date.wholeMilliseconds
        guard whole != date else { return }
        date = whole
        touched = true
    }

    private static func quantize(_ date: inout Date?, _ touched: inout Bool) {
        guard let value = date else { return }
        let whole = value.wholeMilliseconds
        guard whole != value else { return }
        date = whole
        touched = true
    }
}
