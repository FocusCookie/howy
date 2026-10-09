# Howy — Code Review (pre-first-commit)

Scope: everything in the working tree (`project.yml`, `Howy/`, `HowyWidgets/`,
`Packages/HowyCore/`) against `docs/PRD.md`.

## Checks run

| Check                             | Result                                                                                                                             |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `swift test` (Packages/HowyCore)  | 61 tests in 5 suites pass                                                                                                          |
| `xcodebuild … -scheme Howy build` | BUILD SUCCEEDED, **0 compiler warnings** in Howy/HowyWidgets/HowyCore (KeyboardShortcuts builds with `-suppress-warnings`)         |
| App entitlements                  | `app-sandbox = true`, `application-groups = [GQ9M79TF33.io.lichtwart.howy]` (team-prefixed, no `group.`), `get-task-allow` (Debug) |
| Widget .appex entitlements        | same: sandboxed, `GQ9M79TF33.io.lichtwart.howy`                                                                                    |
| Signing                           | `Apple Development: …`, TeamIdentifier `GQ9M79TF33` (not ad-hoc)                                                                   |
| App Info.plist                    | `LSUIElement = true`, `CFBundleURLTypes` → scheme `howy`                                                                           |
| Widget bundle                     | `Metadata.appintents` present (App Intents metadata extracted)                                                                     |

Verified as **not** a problem (so the fixer doesn't chase them):

- The main-actor `TodoStore` is used correctly from the widget:
  `WidgetData.openTodos()` hops with `MainActor.run`
  (`HowyWidgets/WidgetData.swift:34`), `CompleteTodoIntent.perform` is
  `@MainActor` (`HowyWidgets/CompleteTodoIntent.swift:21`).
- No retain cycles in the panel setup: `keyHandler` (which holds the model
  strongly) is set to nil in `dismiss()` (`Howy/FloatingPanel.swift:89`).
  `model.close` and `onClose` capture the panel weakly
  (`Howy/AppController.swift:92,103,112`). A ModelContainer per modal is freed
  together with its panel. This costs one Core Data stack open per modal on the
  main thread (tens of ms), but it is not a leak.
- Stale context overwriting widget changes: not reachable today. Every modal
  gets a fresh container (`AppController.swift:134`). To interact with a widget
  you have to click the desktop, which makes the panel lose key focus and close
  without saving.
- App writes reload timelines (`TodoStore.shared` default `didWrite`,
  `TodoStore.swift:48`). The intent reloads through the same path
  (`CompleteTodoIntent.swift:26`) and also when the todo is not found (`:29`).

---

## Findings

### High

**1. Panels close on every `resignKey`, including the brief key-focus changes
that happen on activation. This is the most likely cause of both reported
symptoms.** _(Root cause is plausible; the failure is real.)_

- Where: `Howy/FloatingPanel.swift:71-74` (`resignKey` → `dismiss()`),
  `Howy/AppController.swift:121-129` (deferred `NSApp.activate()` +
  `present()`), `Howy/AppController.swift:29-39` (launch).
- What's wrong: any loss of key status closes the panel at once. Several normal
  system events take key status away briefly, right after the panel is shown:
  - _Deep link from a widget_ (archive icon, title, label): clicking the desktop
    widget activates the widget host or desktop. LaunchServices then delivers
    the URL and activates Howy, and `NSApp.activate()` (cooperative and
    asynchronous) lands some hundreds of ms later. Whichever activation lands
    _after_ `present()` makes the panel lose key status, and the panel closes.
    This matches "archive panel closed itself after 0.5 s".
  - _First hotkey press shortly after launch_: when the app is launched from
    Xcode, `open`, or as a login item, the launch-time activation hand-off (for
    example, Xcode re-activating itself) can arrive after the panel is up. The
    panel then closes before the user sees it, which matches "first press ~3 s
    after launch didn't open". The synchronous `SMAppService.register()` +
    ModelContainer open in `start()` (`AppController.swift:33-34`) can also
    delay that first event.
  - _Menu bar → Archive/Quick Add_: the single `DispatchQueue.main.async`
    (`AppController.swift:122`) may not be enough for the menu's teardown to
    finish restoring key status.
- Failure scenario: click the archive icon in the Matrix widget. The archive
  appears, then closes about 0.5 s later with no user action.
- Suggested fix:
  - (a) Instrument first: in `resignKey`, log `NSApp.keyWindow`,
    `NSApp.isActive`, `NSWorkspace.shared.frontmostApplication`, and the time
    since `present()`.
  - (b) Don't close on `resignKey` directly. Defer the check
    (`DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)`) and close only if
    the panel is still not key _and_ another app's window has become key (or
    `NSWorkspace.didActivateApplicationNotification` fired for another app).
    Otherwise call `makeKey()` again.
  - (c) Ignore resigns during a short grace period (~0.5 s) after `present()`.
  - (d) For deep links, call `NSApp.activate()` and present the panel only once
    `NSApplication.didBecomeActiveNotification` fires (with a timeout fallback).
  - (e) Move `SMAppService.register()` and the launch purge off the launch path
    (`Task { }` after launch).

**2. In edit mode, ⌘⌫ pressed in the quadrant picker turns on a delete
confirmation the user can't see. The next Enter deletes the todo.**

- Where: `Howy/QuickEntryView.swift:17-21` (the picker _replaces_ `fields`),
  `Howy/QuickEntryView.swift:86-88` (`DeleteConfirmation` is only inside
  `fields`), `Howy/QuickEntryModel.swift:26-38`.
- What's wrong: `QuickEntryModel.handle(.commandDelete)` sets
  `isConfirmingDelete = true` in any phase when editing. While
  `phase == .pickingQuadrant`, the confirmation view isn't rendered. From then
  on, every Enter/⌘Enter goes to `confirmDelete()`, and every other key is
  swallowed (returns `true`).
- Failure scenario: open a todo from the widget, press ⇧⇥ to change its
  quadrant, accidentally press ⌘⌫, then press ↓ and Enter to choose the
  quadrant. The todo is permanently deleted (it skips the archive) without a
  visible prompt.
- Suggested fix: render `DeleteConfirmation` outside the `if/else` (for example,
  in the footer area) so it shows in every phase. Or ignore `.commandDelete`
  while `phase == .pickingQuadrant`. Better still, move the confirm state into
  `QuickEntryFlow` (see #9) so it's unit-tested.

### Medium

**3. The title field selects all text when it regains focus, so the next
keystroke replaces the whole title.**

- Where: `Howy/QuickEntryView.swift:25-28` (focus moves on phase change) and
  `Howy/QuickEntryView.swift:37-47` (`moveCaretToEnd()` runs only once, in
  `onAppear`, only in edit mode).
- What's wrong: when an `NSTextField` becomes first responder, its field editor
  selects all of its contents. The code works around this only for the first
  focus in edit mode. Every later focus of the title selects all again: ⇧⇥ from
  note → title, digit/Enter from picker → title (create _and_ edit), clicking
  the quadrant chip and picking again.
- Failure scenario: in edit mode, press ⇧⇥ (to picker), then 2 (→ Not Urgent &
  Important). The title is now fully selected. Typing " today" replaces the
  title with "today".
- Suggested fix: call `moveCaretToEnd()` in the deferred block in
  `onChange(of: flow.phase)` whenever the new field is `.title`. Better: hold a
  reference to the panel (pass it in, or use an `NSViewRepresentable` hook)
  instead of searching `NSApp.windows` for the key panel.

**4. ⌘Enter while the delete confirmation is shown deletes the todo.**

- Where: `Howy/QuickEntryModel.swift:28`.
- What's wrong: `.flow(.commandEnter)` confirms the delete. ⌘Enter is the "save"
  muscle-memory key throughout the modal.
- Failure scenario: the user presses ⌘⌫ by mistake, reads the prompt too quickly
  and presses ⌘Enter to "save and go". The todo is deleted, not saved.
- Suggested fix: confirm only with Enter or ⌘⌫ again (or the Delete button).
  Treat ⌘Enter as "cancel delete" or ignore it.

**5. Failures are silent: the shortcut does nothing, typed text is lost, and the
widget shows an empty matrix.**

- Where: `Howy/AppController.swift:134-141` (`freshStore()` returns nil →
  `showQuickEntry`/`showEdit`/`showArchive` return without showing anything),
  `Howy/QuickEntryModel.swift:79-90` (`persist()` logs and then `close()` runs
  anyway), `HowyWidgets/WidgetData.swift:33-42` (read failure → `[:]` → every
  quadrant shows "Nothing here").
- Failure scenario: the App Group container can't be opened (for example, an
  expired or changed provisioning profile, or a store migration error). The
  hotkey appears dead, a capture is thrown away after ⌘Enter, and the desktop
  widget says every quadrant is empty. None of these says why.
- Suggested fix: keep the panel open and show an inline error when `persist()`
  throws (don't call `close()`). Show a panel with a short error when the store
  can't be opened. Give the widget entry an error state ("Can't read Howy data")
  so it isn't confused with an empty matrix. Together these also give the user a
  visible form of the PRD's "if the group ever fails" fallback.

**6. Small Quadrant widget: tapping a title probably opens Quick Add instead of
the edit modal.** _(Plausible; verify on device.)_

- Where: `HowyWidgets/QuadrantWidget.swift:43` (`.widgetURL(quickAdd)` on the
  whole view), `HowyWidgets/QuadrantSectionView.swift:49,88` (`Link`s).
- What's wrong: WidgetKit documents `systemSmall` as a single tap target that
  uses `widgetURL`, and `Link`s inside it are ignored. Buttons with App Intents
  still work. So in the small size, a tap on a title (and on the label) probably
  goes to `howy://quick-add/<n>`.
- Failure scenario: on a small Q1 widget, click "Call the landlord". Quick Add
  opens, not the edit modal. This means PRD story 27 isn't met for small
  widgets.
- Suggested fix: check by hand on macOS 27. If confirmed, either accept and
  document it (small = quick add plus checkbox), or remove `widgetURL` for
  `.systemMedium` only and keep it for small. Note the limitation in the PRD's
  manual checklist.

**7. Widget reloads from a background app are subject to WidgetKit's reload
budget.** _(Plausible.)_

- Where: `Packages/HowyCore/Sources/HowyCore/TodoStore.swift:84-87,194-197`.
- What's wrong: Howy writes from a non-activating panel, so the app is usually
  _not_ the active app when it calls `reloadAllTimelines()`. Reloads requested
  by an app that isn't in the foreground count against the widget's daily budget
  and can be coalesced or delayed. Debug builds with WidgetKit developer mode /
  an attached debugger have no budget, so manual testing won't show this.
- Failure scenario: after a few dozen captures, edits and purges in a day, a new
  todo takes minutes to appear on the desktop. That breaks PRD story 13
  ("immediately").
- Suggested fix: test a Release build without the debugger. If it is throttled,
  skip reloads for purges that removed nothing (already done), and don't reload
  on no-op writes such as `complete` on an already-archived todo
  (`TodoStore.swift:115-119` always commits). Document the limitation if nothing
  else helps.

**8. Focus may not return to the previous app after a deep-link modal closes.**
_(Plausible.)_

- Where: `Howy/AppController.swift:115-119, 124-127`.
- What's wrong: `activatedForPanel` is set only if `!NSApp.isActive` when the
  deferred block runs. LaunchServices usually activates the URL's target app
  itself while delivering `application(_:open:)`. If that activation has already
  happened, `activatedForPanel` stays false, `NSApp.hide(nil)` is never called,
  and Howy stays the active app with no windows.
- Failure scenario: click a todo title in a widget, edit it, press ⌘Enter. The
  panel closes, but keystrokes go nowhere until you click another app.
- Suggested fix: for deep links (`activate: true`), always record that we should
  hide on close. Or record `NSWorkspace.shared.frontmostApplication` before
  presenting and call `activate()` on it after closing.

**9. Panel key logic lives in the untested app target. `PanelKey` and the
delete-confirmation state belong in core.** _(Test gap and code quality.)_

- Where: `Howy/Shortcuts.swift:17-44` (keyCode → key mapping),
  `Howy/QuickEntryModel.swift:25-45` (delete-confirm mode, empty-title hint),
  `Howy/AppController.swift:98-102` (swallowing keys in the picker).
- What's wrong: the PRD says the modal is "a thin view over" the state machine.
  But the delete-confirm sub-state, the "swallow keys in picker" rule and the
  key mapping all sit in the app target, which has no tests. Bugs #2 and #4 are
  in exactly this code.
- Suggested fix: add `.commandDelete` to `QuickEntryKey` and a
  `confirmingDelete` flag/phase to `QuickEntryFlow` (edit mode only; Enter
  confirms, Esc and others cancel). Add flow tests for it. Move the pure part of
  the key mapping into core as `QuickEntryKey(keyCode:modifiers:characters:)`,
  which is testable without `NSEvent`.

**10. Markdown rendering is inline-only, so lists and headings show as raw
text.** _(PRD 14 and 34 only partly met.)_

- Where: `Howy/QuickEntryView.swift:192-195`
  (`.inlineOnlyPreservingWhitespace`).
- What's wrong: bold, italics, code and links render. "- item" lists and "#
  headings" appear as plain characters. The PRD explicitly names lists.
- Failure scenario: a note with "- buy milk\n- call Bob" shows its dashes
  unchanged in the preview.
- Suggested fix: parse with `.full`, then walk the `PresentationIntent` runs to
  build list bullets and line breaks (a small renderer, no extra dependency). Or
  accept inline-only and update the PRD. Also check whether tapping a link in
  the preview opens the browser _and_ enters edit mode
  (`QuickEntryView.swift:81-83`).

### Low

**11. The global shortcut while an _edit_ modal is open throws away the edit
instead of opening Quick Add.**

- Where: `Howy/AppController.swift:58-64`, `:104` (`isQuickEntry: true` is
  passed for edit modals too).
- What's wrong: `panelIsQuickEntry` is true for edit panels, so
  `toggleQuickEntry()` closes them. The name says otherwise.
- Suggested fix: track the panel kind
  (`enum PanelKind { quickEntry, edit, archive }`) and decide on purpose. For
  example, toggle only closes a create-mode panel.

**12. The login item is registered only once. A failure is never retried, and
the menu toggle can show a stale state.**

- Where: `Howy/AppController.swift:166-177`, `:157-164`,
  `Howy/HowyApp.swift:26-29`.
- What's wrong: the flag is set _before_ `register()` is called. If registration
  throws, it is never attempted again. `.requiresApproval` shows as "off" with
  no hint. The status is not refreshed when the user changes it in System
  Settings.
- Suggested fix: set the flag only after success. Refresh `launchesAtLogin` when
  the menu opens (`onAppear` of `MenuContent`). Handle `.requiresApproval` by
  calling `SMAppService.openSystemSettingsLoginItems()`.

**13. The daily purge timer pauses while the Mac sleeps.**

- Where: `Howy/AppController.swift:35-38`.
- What's wrong: `Timer` intervals don't advance during sleep. On a laptop that
  sleeps every night, the "daily" purge may run every few days. The user sees no
  effect, because the archive purges when opened and widgets show only open
  todos, but the code doesn't do what its comment says.
- Suggested fix: also purge on `NSWorkspace.didWakeNotification`, or use
  `NSBackgroundActivityScheduler` with a 24 h interval.

**14. The App Group team ID is hardcoded twice.**

- Where: `Packages/HowyCore/Sources/HowyCore/AppGroup.swift:10` vs
  `project.yml:10` / entitlements `$(TeamIdentifierPrefix)`.
- What's wrong: if the team ever changes, the entitlement follows the new team
  but the code doesn't. `containerURL` then returns nil, and per #5 everything
  fails silently.
- Suggested fix: add an Info.plist key
  (`HowyAppGroup = $(TeamIdentifierPrefix)io.lichtwart.howy`) to both targets
  and read it via `Bundle.main`. Or at least add a comment and a build-time
  check.

**15. Dead or unused code.**

- `QuickEntryFlow.insertText(_:)` (`QuickEntryFlow.swift:185-192`) and
  `highlight(_:)` (`:196-200`): used only by tests. Text goes straight through
  the `TextField` bindings, so the tests of `insertText` exercise code the app
  never runs.
- `QuickEntryModel.requestDelete()` (`Howy/QuickEntryModel.swift:52`): never
  called.
- `WidgetContentBuilder.build(openTodos: [TodoSnapshot] …)`
  (`WidgetContentBuilder.swift:83-95`): used only by tests.
- `FloatingPanel.cancelOperation` (`FloatingPanel.swift:76-78`): Esc is already
  handled by `keyHandler`. In the archive it would close without going through
  `model.close`, which is harmless but means two paths.
- `TodoStore.modelContainer` / `makeSharedContainer()` are public "for
  `.modelContainer(_:)` in SwiftUI", but nothing uses them.
- Suggested fix: delete them, or (for `insertText`) remove the tests that
  pretend it is the app's input path.

**16. While the delete confirmation is shown, letters are typed into the title
but digits are swallowed.**

- Where: `Howy/AppController.swift:99-102` with
  `Howy/QuickEntryModel.swift:26-33`.
- What's wrong: `PanelKey(event:)` returns nil for letters, so they skip
  `model.handle` and edit the title behind the prompt. Digits map to `.digit`
  and are consumed.
- Suggested fix: while confirming, consume every non-command key in `keyHandler`
  (falls out naturally from #9).

**17. An edit link can open an archived todo.**

- Where: `Howy/AppController.swift:72-81` (`store.todo(id:)` doesn't filter on
  `completedAt`).
- What's wrong: a widget with a stale timeline can still link to a todo that has
  just been completed. The edit modal then edits an archived item, and the user
  can't see that it is archived.
- Suggested fix: when `todo.completedAt != nil`, open the archive instead (or
  show "This todo is archived").

**18. A restored todo keeps its old `sortDate`, so it can reappear under "+N
more".**

- Where: `Packages/HowyCore/Sources/HowyCore/TodoStore.swift:121-126`.
- What's wrong: this is consistent with the PRD ("back to its original
  quadrant"), but undoing an accidental tick in a busy quadrant makes the todo
  seem to vanish.
- Suggested fix: product decision. Consider bumping `sortDate` on restore, as
  story 33 does for moves. Add a test for whichever is chosen.

**19. No versioned SwiftData schema.**

- Where: `Packages/HowyCore/Sources/HowyCore/TodoStore.swift:64-71`.
- What's wrong: a later change to the `Todo` model that lightweight migration
  can't handle makes `ModelContainer` throw. Per #5, the app and widget then
  quietly show nothing.
- Suggested fix: wrap the model in `VersionedSchema` v1 now (cheap), with an
  empty `SchemaMigrationPlan`.

**20. Menu item `.globalKeyboardShortcut` may fire Quick Add twice while the
menu is open.** _(Plausible.)_

- Where: `Howy/HowyApp.swift:23`.
- What's wrong: KeyboardShortcuts' `globalKeyboardShortcut` attaches a real
  SwiftUI `.keyboardShortcut` to the menu item. KeyboardShortcuts also handles
  the hotkey while menus are tracking (its `RunLoopLocalEventMonitor` for
  `.eventTracking`). Both can call `showQuickEntry`. This is harmless (the
  second call replaces the first panel) but wasteful.
- Suggested fix: none needed, or display the shortcut without binding it.

**21. Quadrant label hides the count when it is 0.**

- Where: `HowyWidgets/QuadrantSectionView.swift:58-62`.
- What's wrong: this is a small deviation from PRD 17 ("its open-todo count").
  It is fine visually, since the empty state already says "Nothing here".
- Suggested fix: keep it and note it in the PRD, or show a dimmed "0".

---

## PRD conformance (user stories not fully met)

All 47 stories were checked against the code. Fully met unless listed:

| #      | Status              | Note                                                                                       |
| ------ | ------------------- | ------------------------------------------------------------------------------------------ |
| 1      | Partial             | Works, but see #1: the first press after launch can open and then immediately close.       |
| 2      | Met                 | Positioned in the upper third, not vertically centred (Spotlight-like); `.floating` level. |
| 13     | Partial / plausible | Reloads are requested; see #7 (budget) and #5 (silent save failure).                       |
| 14     | Partial             | Inline Markdown only; lists not rendered (#10).                                            |
| 17     | Partial (minor)     | Count hidden at 0 (#21).                                                                   |
| 27     | Partial / plausible | Probably not in the _small_ Quadrant widget (#6).                                          |
| 28     | Partial / plausible | In small, the whole widget goes to quick-add (same effect, so effectively met).            |
| 29, 38 | Partial             | Works, but the archive opened from the widget can close itself (#1).                       |
| 34     | Partial             | Rendered inline only (#10).                                                                |
| 36     | Partial             | Confirmation can be invisible (#2), and ⌘Enter confirms (#4).                              |
| 42     | Met (weakly)        | Purge runs on launch and on archive open; the daily timer drifts with sleep (#13).         |
| 45     | Met                 | Registered on first launch; not retried on failure (#12).                                  |

Implementation decisions:

- "Fallback if the group ever fails: read-only snapshot": not implemented. The
  PRD marks it as a fallback, so that's acceptable, but failures are currently
  invisible (#5).
- "Quick-entry flow … fed key events (… text input)": `insertText` exists but
  the app doesn't use it (#15). Delete confirmation and key mapping sit outside
  the flow (#9).
- "Modal … dismissed on Esc, on save, and on losing focus": implemented, but too
  eagerly (#1).
- Everything else (targets, team-prefixed group, sandbox on both, SwiftData in
  group container, reload after every write, domain model, store interface,
  injected clock, purge timing, KeyboardShortcuts, App Intent configuration,
  deep links, CompleteTodo intent, colours, rendering modes) matches.

## Test gaps vs "Testing Decisions"

The PRD's listed cases are all covered (store: add/update/move ordering,
complete/archive, restore, delete, purge boundary, empty title; flow: arrows +
clamp, 1–4, Tab/Enter, Enter-newline, ⌘Enter title/note, Esc, empty-title,
last-used, edit load and quadrant change; builder: fits/overflow/empty/counts
per family). Gaps:

1. **Delete confirmation** (arm / confirm / cancel / phase interaction):
   untested because it lives in `QuickEntryModel` (#2, #4, #9).
2. **Key mapping** (`PanelKey(event:)`: keypad Enter, ⇧⇥ vs ⇥, ⌘⌫, digit vs
   letters, modifier filtering): untested (#9).
3. Flow: Tab in the note is _not_ consumed; an emptied title blocks save in
   **edit** mode; Shift+Tab from the picker isn't consumed in edit mode. None is
   asserted.
4. Store: `purgeArchive` that removes items fires `didWrite` (only the no-op
   purge is asserted); `complete` on an already archived todo keeps
   `completedAt` (documented at `TodoStore.swift:114` but untested).
5. Store on a real file: two `TodoStore`s on the same on-disk URL (one writes, a
   fresh one reads) would pin down the "fresh container sees other writers"
   assumption that `AppController.freshStore()` depends on. A temp-dir URL works
   without the App Group.
6. `insertText` tests cover a code path the app never uses (#15).

## Top items for the fixer (suggested order)

1. #2 — show or guard the delete confirmation in the picker (real data loss).
2. #1 — instrument, then harden panel dismissal (grace period and delayed
   re-check, activate-then-present for deep links).
3. #3 and #4 — caret on every title refocus; ⌘Enter must not confirm delete.
4. #9 — move delete-confirm and the key mapping into `HowyCore` and test them
   (covers #2, #4 and #16 for good).
5. #5 — surface store, save and widget read failures.
6. #6 and #7 — manual verification on device (small-widget links, reload budget
   in Release).

---

## Outcome

Tests: 61 -> 95 (Swift Testing, 8 suites), all passing.
`xcodebuild ... -derivedDataPath build/DD-fix build`: BUILD SUCCEEDED, no new
warnings. New core tests were written together with the implementation in one
pass (not observed red first). Nothing was launched or committed.

| #   | Result                           | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Fixed (needs device check)       | `FloatingPanel.resignKey` logs diagnostics (appActive, keyWindow, frontmost, time since present). Resigns within 0.6 s of `present()` are undone with `makeKey()`; later ones close only if the panel is still not key 0.15 s later. Deep links now `activate()` and present on `didBecomeActive` (0.5 s fallback). Login item registration and the first purge moved off the launch path into a `Task`. Root cause unconfirmed; read the "Panel resigned key" log lines if it still happens. |
| 2   | Fixed                            | Delete prompt state is in `QuickEntryFlow`; the prompt renders in every phase (outside the picker/fields switch).                                                                                                                                                                                                                                                                                                                                                                             |
| 3   | Fixed                            | Caret moved to end whenever the title gets focus; panel found through a `WindowReader` instead of scanning `NSApp.windows`.                                                                                                                                                                                                                                                                                                                                                                   |
| 4   | Fixed                            | While the prompt shows: Enter or second ⌘⌫ confirms, ⌘Enter is ignored, anything else dismisses the prompt.                                                                                                                                                                                                                                                                                                                                                                                   |
| 5   | Fixed                            | Save/delete failures keep the panel open with an inline error (`flow.reopen()`). Store can't open: an error panel is shown. Widgets get `readFailed` and show "Can't read Howy data" (retry in 5 min). Purge at launch/wake stays quiet on failure.                                                                                                                                                                                                                                           |
| 6   | Partly fixed, needs device check | `widgetURL` is now set only in the small family (before it also covered medium, where it could shadow nothing but was pointless). Small still opens Quick Add on any tap, as the review expected; a title tap cannot open edit there. Accepted limitation: small = quick add + checkbox. Not changed further without checking on macOS 27.                                                                                                                                                    |
| 7   | Partly fixed, needs device check | No-op `complete` (already archived) and `restore` (already open) no longer commit or reload. Reload budget in a Release build without debugger still to be tested; nothing else to do in code.                                                                                                                                                                                                                                                                                                |
| 8   | Fixed (needs device check)       | Deep links always hide on close (not only when we activated), then re-activate the app that was frontmost before. Not done when the panel closed because focus went elsewhere.                                                                                                                                                                                                                                                                                                                |
| 9   | Fixed                            | `.commandDelete` and `.other` keys, the delete state, empty-title hint and picker swallow rule are in `QuickEntryFlow`. Key mapping is `QuickEntryKey(keyCode:modifiers:characters:)` in core (`KeyMapping.swift`), with tests. `PanelKey` removed.                                                                                                                                                                                                                                           |
| 10  | Fixed, link tap not changed      | Block-level Markdown (`MarkdownBlocks` in core, tested; the view renders paragraphs, headings, bullet/numbered/nested lists, code, quotes). Soft line breaks are kept as newlines. Not checked: tapping a link in the preview may also enter edit mode. Needs device check.                                                                                                                                                                                                                   |
| 11  | Fixed                            | `PanelKind`; only a quick-entry panel toggles closed. The shortcut with an edit panel open opens Quick Add (replacing the edit panel, discarding its changes).                                                                                                                                                                                                                                                                                                                                |
| 12  | Fixed                            | Flag set only after a successful register (or when already enabled). State refreshed on menu open. `.requiresApproval` opens System Settings > Login Items. The menu `onAppear` refresh is untested on device.                                                                                                                                                                                                                                                                                |
| 13  | Fixed                            | Also purges on `NSWorkspace.didWakeNotification`.                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 14  | Fixed                            | Both targets carry Info.plist `HowyAppGroup = $(TeamIdentifierPrefix)io.lichtwart.howy` (verified expanded in the built plists). `HowyAppGroup.identifier` reads it; the hardcoded value is only a tested fallback.                                                                                                                                                                                                                                                                           |
| 15  | Fixed                            | Removed `insertText` (and its tests), `highlight`, `requestDelete` on the model, flat `WidgetContentBuilder.build`, `FloatingPanel.cancelOperation`, `makeSharedContainer` (now private `makeContainer`), and made `TodoStore.modelContainer` internal.                                                                                                                                                                                                                                       |
| 16  | Fixed                            | All non-command keys are consumed while the prompt shows (via #9).                                                                                                                                                                                                                                                                                                                                                                                                                            |
| 17  | Fixed                            | An edit link for an archived todo opens the archive.                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 18  | Fixed (product decision)         | `restore` bumps `sortDate`, so a restored todo appears on top. Tested.                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 19  | Fixed                            | `HowySchemaV1` + empty `HowyMigrationPlan` used by all containers. Existing on-device stores should open unchanged (same model); check on first run.                                                                                                                                                                                                                                                                                                                                          |
| 20  | No change needed                 | Harmless double call, as the review said.                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| 21  | Fixed                            | Count is shown at 0, dimmed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

Test gaps from the review: 1 (delete confirmation) done, 2 (key mapping) done, 3
(flow edge cases) done, 4 (purge fires didWrite, complete keeps completedAt)
done, 5 (two stores on one file) done, 6 (`insertText` tests) removed.

Still to check by hand on device:

- Archive icon / title / label deep links from a widget: the panel must stay
  open; first hotkey press after launch; menu bar Quick Add/Archive (#1).
- After closing a deep-link modal with Esc or Save, keyboard focus returns to
  the previous app (#8).
- Small Quadrant widget tap behaviour (#6); widget update speed after a save in
  a Release build without debugger (#7).
- Clicking a link in the note preview does not also enter edit mode (#10).
- Start at Login toggle reflects System Settings changes (#12).
- Existing data still shows after the versioned-schema change (#19).
- Visual look of the new widget error state and the error panel.
