# PRD: Howy — Eisenhower Matrix for the macOS Desktop

## Problem Statement

I use TickTick only for its Eisenhower matrix. Its macOS desktop widget is ugly: a big "Eisenhower Matrix" header wastes space, and it comes in only one size. I want my four quadrants on the desktop, readable at a glance, in the sizes I choose — and I want to capture a todo into the right quadrant in a couple of keystrokes without opening a full task manager.

## Solution

Howy is a small menu-bar app for macOS with desktop widgets:

- A **Matrix widget** (large and extra-large) showing all four quadrants with no header, just a small coloured label and open-todo count per quadrant.
- A **Quadrant widget** (small and medium) showing a single quadrant, chosen per widget instance — so four of them can sit on the desktop side by side.
- A Spotlight-style **quick-entry modal** on a global shortcut (⌃⌥⇧⌘Space): pick a quadrant, type a title, optionally a Markdown note, save.
- Ticking a todo in any widget marks it done; it vanishes into an **archive**, where it can be restored for 7 days before it is deleted automatically.

## User Stories

### Capturing todos

1. As a user, I want to press ⌃⌥⇧⌘Space anywhere, so that I can capture a todo without switching apps.
2. As a user, I want the quick-entry modal to float centred above all windows like Spotlight, so that it feels instant and unobtrusive.
3. As a user, I want the modal to open on a 2×2 quadrant picker, so that I decide priority first.
4. As a user, I want to move the picker selection with the arrow keys and confirm with Enter, so that I never need the mouse.
5. As a user, I want to press 1–4 to choose a quadrant and jump straight to the title (1 = Urgent & Important, 2 = Not Urgent & Important, 3 = Urgent & Unimportant, 4 = Not Urgent & Unimportant), so that capture is even faster.
6. As a user, I want the last quadrant I used to be preselected, so that repeated captures into the same quadrant need just Enter.
7. As a user, I want Tab or Enter in the title field to move to the note field, so that adding detail flows naturally.
8. As a user, I want ⌘Enter to save from the title field, so that I can skip the note.
9. As a user, I want Enter in the note field to insert a line break, so that I can write multi-line notes.
10. As a user, I want ⌘Enter in the note field to save, so that saving is consistent everywhere.
11. As a user, I want Esc to cancel and close the modal without saving, so that I can back out safely.
12. As a user, I want an empty title to block saving, so that I don't create blank todos.
13. As a user, I want the modal to close and the widgets to update immediately after saving, so that I see my todo on the desktop right away.
14. As a user, I want to write notes in Markdown, so that I can use lists, bold and links in longer text.

### Viewing todos on the desktop

15. As a user, I want a Matrix widget in large and extra-large sizes showing all four quadrants, so that I see my whole matrix at a glance.
16. As a user, I want the Matrix widget to have no big title header, so that space goes to my todos.
17. As a user, I want each quadrant to show a small coloured label (red, orange, blue, green like TickTick) and its open-todo count, so that I can tell quadrants apart and see their load.
18. As a user, I want a Quadrant widget in small and medium sizes, so that I can place individual quadrants where I like.
19. As a user, I want to choose which quadrant each Quadrant widget shows, so that I can add four of them, one per quadrant.
20. As a user, I want widgets to show titles only, so that they stay clean.
21. As a user, I want the newest todos at the top of each quadrant, so that recent captures are visible.
22. As a user, I want a "+N more" line when a quadrant has more todos than fit, so that I know something is hidden.
23. As a user, I want widgets to follow light and dark mode and the system's tinted widget style, so that they look native on my desktop.
24. As a user, I want an empty quadrant to show a quiet empty state, so that it doesn't look broken.

### Working with todos from the widgets

25. As a user, I want to tick a todo's checkbox directly in the widget, so that I can complete it without opening anything.
26. As a user, I want a completed todo to disappear from the widget right away, so that the widget only shows open work.
27. As a user, I want to click a todo's title in a widget to open it in the edit modal, so that I can read or change its note.
28. As a user, I want to click a quadrant's label in a widget to open quick entry with that quadrant preselected, so that adding to a specific quadrant is one click.
29. As a user, I want a small archive icon in the Matrix widget, so that I can reach the archive from the desktop.

### Editing todos

30. As a user, I want the edit modal to look like the quick-entry modal, so that there is one familiar interface.
31. As a user, I want to change a todo's title and note in the edit modal, so that I can refine it.
32. As a user, I want to change a todo's quadrant in the edit modal, so that I can re-prioritise it.
33. As a user, I want a moved todo to appear at the top of its new quadrant, so that I notice where it went.
34. As a user, I want the note shown rendered as Markdown and switch to raw text when I click into it, so that it reads nicely and stays editable.
35. As a user, I want ⌘Enter to save my edits and Esc to discard them, so that editing works like capture.
36. As a user, I want ⌘⌫ to delete a todo after a confirmation, so that I can remove todos I won't do without them cluttering the archive.

### Archive

37. As a user, I want completed todos to go into a single archive, so that nothing is lost the moment I tick it.
38. As a user, I want to open the archive from the menu bar and from the Matrix widget, so that it is always reachable.
39. As a user, I want the archive to list todos newest-completed first, each tagged with its original quadrant, so that I can find recent work.
40. As a user, I want to restore an archived todo back to its original quadrant, so that I can undo an accidental tick.
41. As a user, I want to delete an archived todo immediately, so that I can clean up by hand.
42. As a user, I want archived todos older than 7 days to be deleted automatically, so that the archive stays small without effort.

### App behaviour

43. As a user, I want Howy to live in the menu bar with no Dock icon, so that it stays out of the way.
44. As a user, I want the menu bar menu to offer Quick Add, Archive and Quit, so that every function is reachable without the shortcut.
45. As a user, I want Howy to start at login, so that the shortcut and widgets always work.
46. As a user, I want all data stored locally on my Mac, so that it is private and works offline.
47. As a user, I want all UI text in English, so that it matches my other tools.

## Implementation Decisions

- **Platform:** native Swift and SwiftUI, targeting macOS 27, built with Xcode 27. Widgets via WidgetKit; widget interactivity (checkbox) via App Intents running in the widget process.
- **Targets:** a menu-bar app (no Dock icon, launch at login), a widget extension containing both widget kinds, and a shared core module used by both.
- **Signing:** automatic signing with the user's free Personal Team ("Apple Development"), not "Sign to Run Locally". Both the app and the widget extension are sandboxed (macOS will not load an unsandboxed widget).
- **Data sharing:** a team-prefixed App Group (`$(TeamIdentifierPrefix)` + reverse-DNS suffix) on both targets. The `group.` prefix form is deliberately avoided: on recent macOS it requires registration a free team cannot do, and the widget silently fails to load. Fallback if the group ever fails: the app writes a read-only snapshot the widget reads via a home-relative temporary sandbox exception.
- **Persistence:** SwiftData store inside the App Group container, opened by both app and widget. After every write the writer reloads all widget timelines.
- **Domain model:**
  - `Quadrant`: four cases in reading order — urgentImportant (1), notUrgentImportant (2), urgentUnimportant (3), notUrgentUnimportant (4). Each carries its display name, colour and shortcut number.
  - `Todo`: id, title (non-empty), note (Markdown text, may be empty), quadrant, createdAt, sortDate (set on creation and on quadrant move; drives newest-first ordering), completedAt (nil when open).
  - A todo is **open** when completedAt is nil and **archived** otherwise. No separate archive entity.
- **Todo store (core module, deep interface):** add(title, note, quadrant); update(id, title, note, quadrant), where a quadrant change bumps sortDate; complete(id); restore(id) (clears completedAt, keeps original quadrant); delete(id); purgeArchive(now) (removes archived todos completed more than 7 days before `now`); openTodos(in quadrant) newest-first; archivedTodos() newest-completed first. Time is injected via a clock so purge is testable.
- **Purge timing:** purge runs on app launch, on archive open, and on a daily timer while the app runs.
- **Quick-entry flow:** a UI-independent state machine fed key events (arrows, 1–4, Enter, Tab, ⌘Enter, Esc, text input). States: pickingQuadrant → editingTitle → editingNote → saved | cancelled. Modes: create (preselects last-used quadrant, persisted) and edit (loaded from an existing todo, quadrant changeable). The SwiftUI modal is a thin view over it.
- **Modal window:** a borderless, floating, non-activating panel centred on the active screen, Spotlight-style; dismissed on Esc, on save, and on losing focus.
- **Global shortcut:** ⌃⌥⇧⌘Space, registered via the KeyboardShortcuts package (Carbon hotkey API). Works in the sandbox with no Accessibility permission.
- **Widget content builder:** a pure function from (open todos per quadrant, widget family, selected quadrant) to view content: the visible titles that fit the family's capacity, open count, and overflow count for "+N more". Widget views only render its output.
- **Widget configuration:** the Quadrant widget uses an App Intent configuration with a quadrant parameter.
- **Widget deep links:** a todo tap opens the app's edit modal for that todo; a quadrant-label tap opens quick entry with that quadrant preselected; the archive icon opens the archive modal. Implemented via a custom URL scheme handled by the menu-bar app.
- **Widget checkbox:** a CompleteTodo App Intent with the todo id; it calls the store's complete and reloads timelines.
- **Archive modal:** same panel style as quick entry; a list of archived todos with quadrant tag and per-row Restore and Delete actions.
- **Markdown:** rendered with SwiftUI's built-in Markdown support (AttributedString) in the edit modal; raw text while editing.
- **Colours:** red, orange, blue, green for quadrants 1–4. Respect light/dark mode and the tinted/accented widget rendering mode.
- **Axiom skills** (macOS, integration, SwiftUI, data) guide the implementation, except their `group.` App Group convention, which is overridden by the team-prefixed decision above.

## Testing Decisions

- A good test exercises only external behaviour through a module's public interface: given inputs and state, check outputs and resulting state. No assertions on private helpers, view hierarchies or SwiftData internals.
- Framework: Swift Testing.
- **Todo store:** tested against an in-memory SwiftData container with an injected fake clock. Cases: add/update/move ordering, complete hides from open and shows in archive, restore returns to the original quadrant, delete, purge removes exactly items older than 7 days, empty title rejected.
- **Quick-entry flow:** tested by feeding key-event sequences and asserting the resulting state and the saved draft. Cases: arrow navigation and wrap/clamp, 1–4 shortcuts, Tab/Enter field transitions, Enter-as-newline in the note, ⌘Enter save from title and note, Esc cancel, empty-title block, last-used preselection, edit mode loading and quadrant change.
- **Widget content builder:** tested per widget family with varying todo counts: fits exactly, overflow and "+N more", empty quadrant, counts.
- **Manual checklist (not automated):** widget appearance in light/dark/tinted modes, widget gallery availability, global shortcut, App Group sharing between app and widget, checkbox App Intent, deep links, launch at login, menu-bar-only behaviour.
- Prior art: none. This is a new repo, and these tests set the pattern.

## Out of Scope

- iCloud or any sync; iPhone/iPad apps.
- Importing from TickTick.
- Due dates, reminders, tags, subtasks, lists/projects beyond the four quadrants.
- Manual drag-to-sort and drag between quadrants (moving is done in the edit modal).
- A main matrix window.
- Distribution (App Store, notarisation). Personal use only.
- Markdown in widgets.

## Further Notes

- Free Personal Team profiles expire after 7 days. Because the project uses only non-restricted entitlements (App Sandbox, team-prefixed App Group), an expired profile should not stop the app or widget from launching on macOS. This is untested; rebuilding in Xcode renews the profile anyway.
- If the widget doesn't appear in the gallery, first check Console for "Group containers identifiers should be prefixed" and confirm the extension is sandboxed.
- Avoid Option-only or Option+Shift-only shortcuts (broken on macOS 15+); the chosen four-modifier combo is unaffected.
