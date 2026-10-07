# PRD: Howy — Eisenhower Matrix for the macOS Desktop

## Problem Statement

I use TickTick only for its Eisenhower matrix. Its macOS desktop widget is ugly: a big "Eisenhower Matrix" header wastes space, and it comes in only one size. I want my four quadrants on the desktop, readable at a glance, in the sizes I choose — and I want to capture a todo into the right quadrant in a couple of keystrokes without opening a full task manager.

## Solution

Howy is a small menu-bar app for macOS with desktop widgets:

- A **Matrix widget** (large and extra-large) showing all four quadrants with no header, just a small coloured label and open-todo count per quadrant.
- A **Quadrant widget** (small and medium) showing a single quadrant, chosen per widget instance — so four of them can sit on the desktop side by side.
- A Spotlight-style **quick-entry modal** on a global shortcut (⌃⌥⇧⌘Space): pick a quadrant, type a title, optionally a Markdown note, save.
- A **browse modal** on a second shortcut (⌃⌥⇧⌘M): the same quadrant picker showing each quadrant's open count, then that quadrant's todos to open or tick off.
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
11. As a user, I want Esc to close the modal without saving but keep my typed text as a draft, so that I can back out without losing anything.
12. As a user, I want an empty title to block saving, so that I don't create blank todos.
13. As a user, I want the modal to close and the widgets to update immediately after saving, so that I see my todo on the desktop right away.
14. As a user, I want to write notes in Markdown, so that I can use lists, bold and links in longer text.
14a. As a user, I want my unsaved quick-entry draft (quadrant, title, note) restored the next time I open quick entry — after Esc, clicking away or even an app restart — so that I never lose typed text.
14b. As a user, I want ⌘⌫ in quick entry to clear the draft and return to the picker, so that I can deliberately start over.
14c. As a user, I want the modal to have a translucent glass background like Spotlight, so that it feels native and light.
14d. As a user, I want the modal to open with a Spotlight-like animation — fading in while settling from slightly larger to its size, with the four quadrant tiles sliding a few points from the corners into place — so that it feels polished (fade only when Reduce Motion is on).
14e. As a user, I want the selected quadrant in the picker to glow softly in its colour, so that the selection is obvious.

### Viewing todos on the desktop

15. As a user, I want a Matrix widget in large and extra-large sizes showing all four quadrants, so that I see my whole matrix at a glance.
16. As a user, I want the Matrix widget to have no big title header, so that space goes to my todos.
17. As a user, I want each quadrant to show a small coloured label (red, orange, blue, green like TickTick, no dot in front) and its open-todo count, so that I can tell quadrants apart and see their load.
18. As a user, I want a Quadrant widget in small and medium sizes, so that I can place individual quadrants where I like.
19. As a user, I want to choose which quadrant each Quadrant widget shows, so that I can add four of them, one per quadrant.
20. As a user, I want widgets to show titles only, so that they stay clean.
21. As a user, I want the newest todos at the top of each quadrant, so that recent captures are visible.
22. As a user, I want a "+N more" line when a quadrant has more todos than fit, so that I know something is hidden.
23. As a user, I want widgets to follow light and dark mode and the system's tinted widget style, so that they look native on my desktop.
24. As a user, I want an empty quadrant to show a quiet empty state, so that it doesn't look broken.
24a. As a user, I want the Matrix widget to show four separate translucent tiles with the desktop visible between them, rather than one big panel behind them, so that it looks light.
24b. As a user, I want widgets to stay visible while I switch between desktops (Spaces), like Apple's own widgets, so that they don't flicker.

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
34. As a user, I want the note styled as Markdown live while I type (headings, bold, italic, code, lists, quotes, links styled; syntax characters dimmed), in both quick entry and edit, so that it reads nicely and stays editable in one place.
34a. As a user, I want Enter inside a Markdown list item to continue the list with the next marker (`- `, `2. `, `- [ ] `, same indentation), and Enter on an empty item to end the list, so that I don't retype markers.
35. As a user, I want ⌘Enter to save my edits and Esc to discard them, so that editing works like capture.
35a. As a user, I want unsaved edits kept when the edit modal closes because I clicked away, and restored when I reopen the same todo, so that a stray click doesn't lose them.
36. As a user, I want ⌘⌫ to delete a todo after a confirmation, so that I can remove todos I won't do without them cluttering the archive.

### Browsing

36a. As a user, I want to press ⌃⌥⇧⌘M (or choose Browse in the menu) to open a modal with the quadrant picker showing each quadrant's open-todo count, so that I can check a quadrant without looking at the desktop.
36b. As a user, I want to choose a quadrant with 1–4 or arrows + Enter and see its open todos newest first, so that I can review it.
36c. As a user, I want ↑/↓ to select a todo, Enter to open it in the edit modal and `d` to mark it done, so that I can work through a quadrant from the keyboard.
36d. As a user, I want 1–4 to switch quadrant in the list and Esc or ⇧⇥ to go back to the picker (Esc in the picker closes), so that navigation is quick.
36e. As a user, I want to click a row to edit it and tick its checkbox to complete it, so that the mouse works too.
36f. As a user, I want Esc in a todo I opened from Browse to bring me back to its list, Esc in the list to bring me back to the quadrants, and only Esc on the quadrants or clicking elsewhere to close the modal, so that I can work through several todos in one go.

### Attachments

48. As a user, I want to attach files (mostly screenshots) to a todo, so that the todo carries the extra information I captured.
49. As a user, I want a small drop area under the note in quick entry and edit (title, divider, note, divider, drop area), so that attachments have an obvious home without taking much space.
50. As a user, I want ⌘V in the note to attach a copied image or a file copied in Finder and insert a Markdown reference where the caret is (`![attachment-1](attachment-1.png)` for images, `[report.pdf](report.pdf)` for other files), so that the note says where the screenshot belongs.
51. As a user, I want dropping files onto the note to attach them with an inline reference, and dropping onto (or clicking) the drop area to attach them without one, so that I choose whether the note mentions them.
52. As a user, I want pasted images named attachment-1, attachment-2, … per todo (next = highest + 1), and dropped or picked files to keep their own names, so that references are short and easy to recognise.
53. As a user, I want small thumbnails in the drop area in the order I added them (images previewed, other files with their icon), so that I see what is attached.
54. As a user, I want the hovered or keyboard-selected attachment's name shown centred in the divider above the drop area (`──── attachment-1.png ────`, a plain line otherwise), so that I can read names without tooltips.
55. As a user, I want the thumbnail to light up when the caret is on (or the pointer hovers) its reference in the note, and the reference to be highlighted when I hover or select the thumbnail, so that I see which text belongs to which file.
56. As a user, I want ⌥↩ in the title or note to move into the attachment area, ←→ to select, Space or ↩ to open, ⌥↩ (or ⌥-click) to open the other way, ⌫ to remove, → past the last attachment to select the Add button (where ↩ or Space picks files; it is the only stop when there are none), and ⇧⇥ to go back to the note, so that attachments work from the keyboard; Tab in the note still types a tab.
57. As a user, I want to choose in Settings whether attachments open in Quick Look (default; the panel stays and I'm back where I was) or in their default app (the panel closes like on any focus loss, my edit is kept), and a click to follow that setting, so that opening works the way I prefer.
58. As a user, I want removing a thumbnail (hover ✕ or ⌫) to also remove its reference from the note, while deleting the reference text keeps the attachment, so that I never get dead links and never lose a file by editing text.
59. As a user, I want attachment changes to follow the edit: kept only when I save, thrown away with Esc, and carried along in unsaved drafts, so that attachments behave like the title and note.
60. As a user, I want a paperclip (with a count above one) on todos with attachments in the Browse list, the widgets and the archive, so that they are easy to spot.
61. As a user, I want attachments kept while a todo is archived (restored with it) and deleted with the todo, so that nothing lingers or disappears early.

### Archive

37. As a user, I want completed todos to go into a single archive, so that nothing is lost the moment I tick it.
38. As a user, I want to open the archive from the menu bar and from the Matrix widget, so that it is always reachable.
39. As a user, I want the archive to list todos newest-completed first, each tagged with its original quadrant, so that I can find recent work.
40. As a user, I want to restore an archived todo back to the top of its original quadrant, so that I can undo an accidental tick and see it again.
41. As a user, I want to delete an archived todo immediately, so that I can clean up by hand.
42. As a user, I want archived todos older than 7 days to be deleted automatically, so that the archive stays small without effort.

### App behaviour

43. As a user, I want Howy to live in the menu bar with no Dock icon, so that it stays out of the way.
36g. As a user, I want to reorder the todos in a Browse list by dragging the grip on the right of a row, so that each quadrant shows them in the order I want to work on them, here and in the widgets.
36h. As a user, I want ⌘J / ⌘↓ and ⌘K / ⌘↑ to move the selected todo (pointing at a row selects it) one row down or up, so that I can reorder with the keyboard.
36i. As a user, I want ⌘Z in Browse to take back a todo I just marked done (or archived with ⌫), putting it back where it was, so that a slip of the finger doesn't send me into the archive; pressing it again takes back the one before.
44. As a user, I want the menu bar menu to offer Quick Add, Browse, Archive, Settings… (⌘,) and Quit, so that every function is reachable without the shortcut.
44a. As a user, I want a Settings window where I can record and change the Quick Add and Browse shortcuts, so that they don't clash with my other tools, and a button to restore both defaults.
44a1. As a user, I want an option to use one shortcut instead of two, which opens a small chooser (New Todo on the left / 1, Browse on the right / 2), so that I only have to remember one key combination, and to choose which of the two is selected when it opens (New Todo by default), so that Enter alone opens the one I use most; with the option off, Quick Add and Browse keep their own shortcuts.
44b. As a user, I want to choose in Settings which quadrant new todos start on (last used, or a fixed quadrant), so that the picker starts where I usually want it.
44c. As a user, I want the start-at-login toggle in Settings, so that all preferences are in one place.
44d. As a user, I want a random emoji to shoot out of the panel with a small confetti burst when I mark a todo done, and to choose in Settings whether I get both, the emoji alone, or nothing at all, so that finishing something feels good without getting in my way.
45. As a user, I want Howy to start at login, so that the shortcut and widgets always work.
46. As a user, I want all data stored locally on my Mac, so that it is private and works offline.
47. As a user, I want all UI text in English, so that it matches my other tools.

## Implementation Decisions

- **Platform:** native Swift and SwiftUI, targeting macOS 27, built with Xcode 27. Widgets via WidgetKit; widget interactivity (checkbox) via App Intents running in the widget process.
- **Settings:** a plain titled window (not a panel) opened from the menu; the app becomes a regular (Dock) app while it is open so the window reliably takes focus, and returns to accessory mode on close. It holds Howy's own shortcut recorders (not `KeyboardShortcuts.Recorder`, whose field often ignored clicks and recorded fn): a toggle switches between one launcher shortcut and separate Quick Add / Browse shortcuts (only the current mode's fields are shown); click a field to listen, held modifiers show live as key caps, the first key with ⌘/⌃/⌥ (or an F-key alone) is stored, Shift alone is rejected, fn is always dropped, Esc cancels, Delete clears, a click elsewhere stops, Quick Add and Browse may not share a shortcut (refused with a message), and all global shortcuts are paused while listening. The accept/cancel/clear rules are pure and tested in the core package. Settings also has a "Restore Default Shortcuts" button, the new-todo start quadrant (stored in user defaults as 0 = last used, 1–4 = fixed) and the login item toggle. Because KeyboardShortcuts persists a default on first launch, a one-time migration resets a stored ⌃⌥⇧⌘H browse shortcut (the earlier default) to ⌃⌥⇧⌘M; recorded shortcuts are kept. The done animation (emoji + confetti by default, emoji only, or off; stored in user defaults) is set here too.
- **Targets:** a menu-bar app (no Dock icon, launch at login), a widget extension containing both widget kinds, and a shared core module used by both.
- **Signing:** automatic signing with the user's free Personal Team ("Apple Development"), not "Sign to Run Locally". Both the app and the widget extension are sandboxed (macOS will not load an unsandboxed widget).
- **Data sharing:** a team-prefixed App Group (`$(TeamIdentifierPrefix)` + reverse-DNS suffix) on both targets. The `group.` prefix form is deliberately avoided: on recent macOS it requires registration a free team cannot do, and the widget silently fails to load. Fallback if the group ever fails: the app writes a read-only snapshot the widget reads via a home-relative temporary sandbox exception.
- **Persistence:** SwiftData store inside the App Group container, opened by both app and widget. After every write the writer reloads all widget timelines.
- **Domain model:**
  - `Quadrant`: four cases in reading order — urgentImportant (1), notUrgentImportant (2), urgentUnimportant (3), notUrgentUnimportant (4). Each carries its display name, colour and shortcut number.
  - `Todo`: id, title (non-empty), note (Markdown text, may be empty), quadrant, createdAt, sortDate (set on creation and on quadrant move, rewritten by a manual reorder; drives the list order, newest first unless reordered), completedAt (nil when open).
  - A todo is **open** when completedAt is nil and **archived** otherwise. No separate archive entity.
- **Todo store (core module, deep interface):** add(title, note, quadrant); update(id, title, note, quadrant), where a quadrant change bumps sortDate; complete(id); restore(id) (clears completedAt, keeps original quadrant); delete(id); reorder(ids, in quadrant) (manual order); purgeArchive(now) (removes archived todos completed more than 7 days before `now`); openTodos(in quadrant) newest-first; archivedTodos() newest-completed first. Time is injected via a clock so purge is testable.
- **Purge timing:** purge runs on app launch, on archive open, and on a daily timer while the app runs.
- **Quick-entry flow:** a UI-independent state machine fed key events (arrows, 1–4, Enter, Tab, ⇧Tab, ⌘Enter, ⌘⌫, Space, Esc). States: pickingQuadrant → editingTitle → editingNote → saved | cancelled. Modes: create (starts on the quadrant from the "new todos start on" setting: last used (persisted, the default) or a fixed quadrant; a widget-label quadrant overrides it) and edit (starts in the title; ⇧Tab steps back note → title → picker to change the quadrant). It also owns the delete confirmation (shown in every phase; Enter or a second ⌘⌫ confirms, ⌘Enter is ignored, any other key dismisses) and the empty-title hint. Key-code → key mapping lives in core and is tested. The SwiftUI modal is a thin view over it.
- **Drafts:** a draft store in core (UserDefaults-backed, survives restart). Create mode: any close without saving (Esc, focus loss, hotkey toggle, replacement by another panel, quit) stashes quadrant, title, note and field; the next quick entry restores them with the caret at the end; saving or ⌘⌫ clears it. Edit mode: focus loss stashes the unsaved edit per todo id (capped at 20); Esc, save and delete discard it.
- **Browse flow:** a UI-independent state machine in core: picker (with per-quadrant open counts) ↔ list (selection clamped; completing the selected row moves the selection to the next sensible row; reloads after writes). The browse panel is a thin view over it. Pressing ⌃⌥⇧⌘M while browse is open closes it. A todo opened from the list returns to that list on Esc, save or delete (same quadrant, the edited todo or the row now in its place selected); only Esc in the picker or focus loss closes the modal. Rows can be reordered: ⌘↓/⌘J and ⌘↑/⌘K move the selected row (clamped, the selection follows it, `.reorder` tells the caller to write), and dragging a row's grip (a "line.3.horizontal" handle at the right; an AppKit area so the drag never moves the panel) moves it live, with the order written once when the drag ends. Moving the pointer over a row selects it (only real pointer moves, so rows sliding under a resting pointer don't steal the selection). The store's `reorder` rewrites `sortDate` downwards from the newest one already in the quadrant (1 ms apart), so the custom order needs no schema change, also shows in the widgets, and a todo added later still lands on top; an unchanged order writes nothing. In quick entry and edit, these keys stay with the text fields. ⌘Z (picker or list) takes back the last `d` / ⌫ of the open panel: the flow keeps a stack of what it removed and puts the todo back at its old row (`.restore` tells the caller to clear the done mark without bumping `sortDate`, so the position holds); several presses undo several. The stack lives in the flow, so it is gone once the panel closes; later slips go through the archive's Restore. Once there is something to undo, the footer hints show "⌘Z undo".
- **Launcher (single-shortcut mode):** a UI-independent state machine in core: two choices, New Todo and Browse; ←/↑ and →/↓ highlight, 1/2 open directly, Enter/Tab open the highlighted one, Esc closes, other keys are swallowed. A fresh open highlights the choice set in Settings ("Selected first", New Todo by default, stored in user defaults). Opening a choice swaps the screen inside the same panel. Esc from a screen opened this way goes back to the launcher (Quick Add keeps its draft as on any Esc; Browse's Esc on the quadrants; an edited todo still returns to its Browse list first) with that choice highlighted; saving closes. The launcher shortcut closes whatever is open. The mode (separate by default) is stored in user defaults; the menu shows shortcut hints only in separate mode.
- **Modal window:** a borderless, floating, non-activating panel centred on the screen under the mouse, Spotlight-style; dismissed on Esc, on save, and on losing focus (with a short grace period after opening so late activations don't close it). Only one panel at a time; the quick-add hotkey toggles a quick-entry panel and replaces any other panel. A panel that is already on screen is reused: the next screen (launcher → Quick Add, Browse ↔ edit, …) replaces the content inside the one card, which animates to the new height while the screens cross-fade, instead of one panel fading out and another zooming in. Deep-link panels activate the app and hand focus back to the previous app on close.
- **Panel look:** Raycast-style card rather than Liquid Glass (which washed out in light mode): a behind-window blur covered by a near-opaque light or dark fill with a hairline edge, in a continuous rounded rectangle, on a clear, non-opaque window with a soft custom shadow and a transparent margin for the shadow and opening zoom; used by every panel (quick entry, edit, browse, archive, error). Opening: fade + scale 1.05 → 1.0 (snappy, ~0.24 s) while the picker tiles slide ~4 pt from their corners into place; Reduce Motion → fade only. Closing: short fade with a slight shrink. Resting picker tiles and the selected Browse row use neutral grey; the highlighted picker tile is tinted and glows in its quadrant colour (faintly in light mode). Matrix widget tiles use concentric corners, so they follow the widget's rounded mask instead of poking past it.
- **Done animation:** marking a todo done launches a random emoji (never the same twice in a row) out of the card's top edge, above the row that was just ticked: it starts hidden behind the card, grows as it clears the edge, and fades above it (~0.8 s). As it comes out, the card's top edge fires a small confetti burst around it — 18 little flecks that shoot up and outwards in two arms, a V with the emoji rising in the gap, then arc down and fade; deliberately modest, so the emoji stays the star. Both are drawn by a window-wide effects layer masked to the space around the card, so nothing is clipped by the card and nothing is in the way of the pointer or VoiceOver. Settings chooses emoji + confetti (default), emoji only, or nothing; Reduce Motion drops the confetti and the emoji only pops and fades in place.
- **Global shortcuts:** ⌃⌥⇧⌘Space (quick add) and ⌃⌥⇧⌘M (browse), or in single-shortcut mode one launcher shortcut (default ⌃⌥⇧⌘Space), registered via the KeyboardShortcuts package (Carbon hotkey API). All three stay registered and a press only acts in its own mode, so the launcher may share Quick Add's keys. Works in the sandbox with no Accessibility permission.
- **Widget content builder:** a pure function from (open todos per quadrant, widget family, selected quadrant) to view content: the visible titles that fit the family's capacity, open count, and overflow count for "+N more". Widget views only render its output.
- **Widget configuration:** the Quadrant widget uses an App Intent configuration with a quadrant parameter.
- **Widget deep links:** a todo tap opens the app's edit modal for that todo; a quadrant-label tap opens quick entry with that quadrant preselected; the archive icon opens the archive modal. Implemented via a custom URL scheme handled by the menu-bar app.
- **Widget checkbox:** a CompleteTodo App Intent with the todo id; it calls the store's complete and reloads timelines.
- **Archive modal:** same panel style as quick entry; a list of archived todos with quadrant tag and per-row Restore and Delete actions.
- **Markdown:** a live-styled note editor (an NSTextView restyled on every edit, attributes only, so caret, undo and input-method composition are preserved). The Markdown → style-range logic is a pure, tested highlighter in core; syntax characters stay in the text, dimmed.
- **Colours:** red, orange, blue, green for quadrants 1–4. Respect light/dark mode and the tinted/accented widget rendering mode.
- **Widget look:** clear container background with `containerBackgroundRemovable(false)` (the system otherwise replaces it with its own glass panel, which is also the suspected cause of widgets vanishing during Space switches); four separate translucent tiles (neutral base + faint quadrant tint + hairline edge, plain fills rather than materials) with gaps; labels without dots. Accented/vibrant modes use a faint primary fill.
- **Store details:** titles are trimmed; restore bumps sortDate (restored todo returns to the top); writes that change nothing don't commit or reload widgets; a versioned SwiftData schema (v1) with a migration plan.
- **Attachments:** files are copied into the App Group container, no schema change: committed files live in `Attachments/<todo id>/<attachment id>/<name>` with an ordered `attachments.json` manifest per todo; files added during an unsaved edit or draft wait in `Attachments/staging/<attachment id>/<name>`. Saving commits the edit's list (moves staged files in, deletes removed ones, rewrites the manifest, reloads widgets if anything changed). Drafts (quick entry and edit) carry their attachment list; after every finished modal, staged files no stashed draft refers to are deleted (also on launch). Deleting or purging a todo deletes its folder; completing keeps it. Names are unique per todo ("report 2.pdf" on a clash); references in the note are Markdown links whose target is the percent-encoded name (no whitespace), so the note stays plain Markdown. Pure core pieces: naming, reference formatting/finding/removal and caret lookup, the attachment store (file-system backed, tested in a temp folder), and the quick-entry flow's attachment phase (selection, open/remove/pick requests, ⌥↩ / ⇧⇥ transitions). The app adds paste/drop handling in the note editor, a SwiftUI drop area with QuickLookThumbnailing thumbnails, Quick Look via `QLPreviewPanel` (the floating panel is held open and gets key back when it closes), `NSOpenPanel` for picking (needs the user-selected read-only entitlement), and the "Open attachments in" setting (Quick Look / default app, stored in user defaults). Widget, Browse and archive rows show a paperclip from an attachment count on the todo snapshot.
- **Axiom skills** (macOS, integration, SwiftUI, data) guide the implementation, except their `group.` App Group convention, which is overridden by the team-prefixed decision above.

## Testing Decisions

- A good test exercises only external behaviour through a module's public interface: given inputs and state, check outputs and resulting state. No assertions on private helpers, view hierarchies or SwiftData internals.
- Framework: Swift Testing.
- **Todo store:** tested against an in-memory SwiftData container with an injected fake clock. Cases: add/update/move ordering, complete hides from open and shows in archive, restore returns to the original quadrant, delete, purge removes exactly items older than 7 days, empty title rejected.
- **Quick-entry flow:** tested by feeding key-event sequences and asserting the resulting state and the saved draft. Cases: arrow navigation and wrap/clamp, 1–4 shortcuts, Tab/Enter field transitions, Enter-as-newline in the note, ⌘Enter save from title and note, Esc cancel, empty-title block, last-used preselection, the start-quadrant setting (fixed beats last used, preselection beats both), edit mode loading and quadrant change.
- **Widget content builder:** tested per widget family with varying todo counts: fits exactly, overflow and "+N more", empty quadrant, counts.
- **Also tested in core:** attachments (naming, reference format/find/remove/caret lookup, store commit/staging/garbage collection/delete/purge, flow attachment phase and keys, drafts carrying attachments), row reordering (keys, drag moves, store order and new-todo-on-top), launcher flow (highlight, 1/2, Enter/Tab, Esc, finished flow), the shortcut-mode setting and the launcher's start choice, key mapping, delete confirmation, drafts (stash/restore/clear, preselected-quadrant override, edit drafts), browse flow (picker ↔ list, counts, selection after completing), Markdown highlighter, deep links, App Group resolution, two stores on one on-disk file.
- **Manual checklist (not automated):** widget appearance in light/dark/tinted modes, separate tiles without a system panel, widgets staying visible during Space switches, widget gallery availability, both global shortcuts and recording them in Settings, App Group sharing between app and widget, checkbox App Intent, deep links, launch at login, menu-bar-only behaviour, glass panel look, opening animation, picker glow, live Markdown styling (incl. IME and undo), draft survival across restart, attachments (paste/drop/pick, thumbnails, Quick Look and default app, highlight both ways, paperclips), the done emoji and its confetti in all three Settings settings and with Reduce Motion.
- Prior art: none. This is a new repo, and these tests set the pattern.

## Out of Scope

- iCloud or any sync; iPhone/iPad apps.
- Importing from TickTick.
- Due dates, reminders, tags, subtasks, lists/projects beyond the four quadrants.
- Drag between quadrants (moving is done in the edit modal).
- Attachments: rendering images inline in the note, renaming, reordering, size or count limits, thumbnails or opening files from widgets.
- A main matrix window.
- Distribution (App Store, notarisation). Personal use only.
- Markdown in widgets.

## Further Notes

- Free Personal Team profiles expire after 7 days. Because the project uses only non-restricted entitlements (App Sandbox, team-prefixed App Group), an expired profile should not stop the app or widget from launching on macOS. This is untested; rebuilding in Xcode renews the profile anyway.
- If the widget doesn't appear in the gallery, first check Console for "Group containers identifiers should be prefixed" and confirm the extension is sandboxed.
- Avoid Option-only or Option+Shift-only shortcuts (broken on macOS 15+); the chosen four-modifier combo is unaffected.
