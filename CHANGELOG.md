# Changelog

All notable changes to Howy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.5.0] - 2026-10-09

### Added

- **Checklists in notes.** Markdown task items (`- [ ] todo`, `- [x] done`)
  get a dimmed box with an accent-coloured tick, and a ticked item's text is
  crossed out and greyed.
  - **⇧⌘L** in the note turns the selected lines into checklist items (a list
    item keeps its marker, `1.` included). Pressed on items, it ticks them, or
    unticks them when they're all ticked already. On an empty line it starts a
    new `- [ ] ` item.
  - **Click a box** to tick or untick it. The pointer turns into a hand over a
    box and the box gets a soft highlight; the cursor stays where it was.
  - **⌘Z** undoes either in one step. The key hints show **⇧⌘L checklist**
    while you're in the note.

## [1.4.0] - 2026-10-09

### Added

- **New todo from Browse.** Press **N** while you look at a quadrant to add a
  todo to it, also when the quadrant is empty.
  - **In the list**, the create screen opens with the cursor in the title and
    that quadrant already chosen (**Shift-Tab** still reaches the quadrant
    picker). Save, and Browse comes back listing the quadrant you saved into,
    with the new todo selected on top. **Esc** goes back to the list as it was
    and keeps what you typed as a draft; the key hints say **esc back**. The
    Quick Add shortcut there switches to Quick Add with what you typed, like it
    does from the edit screen, instead of closing the panel.
  - **In the Overview**, the editor opens right in the focused tile. Save, and
    the focus moves to the tile you saved into with the new todo selected.
    **Esc**, **⌥1–4** or a click on another tile keeps what you typed as a
    draft.
  - The quadrant you're browsing wins over the _New todo starts in_ setting and
    over the draft's quadrant; the draft's title and note are still restored.
    Quick Add and **N** share one draft, and saving updates the last-used
    quadrant like Quick Add does.
  - The key hints show **N new** next to **↩ edit**.
  - **N** does nothing on the 2×2 quadrant picker.
  - If the list can't be read back after you save in an Overview tile, Browse
    says so instead of quietly not showing the new todo.

### Fixed

- Quick Add opened from the launcher says **esc back** in its key hints, since
  Esc goes back to the launcher.

## [1.3.0] - 2026-10-09

### Added

- **Panel zoom.** Make everything in Howy's panels bigger: **⌘+** (or **⌘=**)
  zooms in, **⌘-** zooms out and **⌘0** goes back to 100 %. There are four
  steps (100, 115, 130 and 150 %); 100 % is the size you know and the smallest.
  The keys work in every panel, also while you type a title or a note, and Howy
  beeps when you're already at the smallest or largest step. Text, rows, icons,
  key caps and the panel's width all grow together, the lists stay within the
  screen, and the Overview keeps its size while its content zooms. The level is
  kept across restarts. Widgets, Settings and Import/Export don't change.
- **Appearance in Settings.** A _Panel size_ slider with the same four steps,
  showing the current percentage. It changes the same setting as the keys.
- **Overview in Browse.** Press **O** (or click the small button in the gap
  where the four quadrants meet) and the panel grows into a large view with all
  four quadrants side by side, each listing its open todos. The counts fade out,
  the four cards grow into the tiles together with the panel, and only then do
  the todos fade in (and the reverse on the way back). With Reduce Motion the
  tiles fade out and back in instead of growing.
  - **1–4** or **⌥1–4** focus a quadrant, and **Tab** / **Shift-Tab** step to
    the next / previous one. The focused tile gets a border in its quadrant
    colour, and a coloured dot before each tile's name matches the move dots.
    Every key you know from a quadrant's list works on the focused tile (↑↓, D,
    ⌫, M, ⌘1–4, ⌘J/⌘K, ⌘Z).
  - **↩** or a click edits a todo right inside its tile, with the other three
    still visible. ⌘↩ saves, ⌘D saves and marks done, Esc discards. Focusing
    another quadrant keeps the edit as a draft.
  - Drag a todo by its grip to another place or another quadrant. A line shows
    where it lands, dropping on a quadrant's header puts it on top, and ⌘Z
    takes it back.
  - **Esc** or the button shrinks the panel back to the four quadrants.
- **Overview size in Settings.** Width and height sliders (50–95 % of the
  screen, 80 % by default) with a live preview of the Overview on your display.
- **Hover on quadrant cards.** The four cards in Browse and in quick entry get a
  touch brighter under the pointer, so you can see what a click opens.

### Changed

- **Settings window uses two columns** so it fits on smaller screens.

## [1.2.0] - 2026-10-09

### Added

- **⌘W closes the Howy panel from any screen.** Esc still steps back (for
  example from the archive to Browse), and ⌘W closes it all at once (⌘Esc does
  the same where macOS lets it through). As when you click away, anything you
  typed is kept as a draft.
- **⌘D marks a todo done from the edit window.** It saves your edits and moves
  the todo to the archive. A **Done** button does the same with the mouse.

### Changed

- **⌘⌫ is plain text editing again in the title and note.** It deletes to the
  start of the line, as everywhere else on the Mac. It used to ask to delete the
  todo (when editing) or clear the whole draft (when adding). Todos are now
  deleted for good only from the archive, and the edit window's Delete button
  is gone.

## [1.1.0] - 2026-10-09

### Added

- **Move a todo to another quadrant from Browse.** In the list, ⌘1–4 sends the
  selected todo to that quadrant, and `M` opens a small "Move to…" picker (1–4,
  or arrows and ↩; esc closes it). With the mouse, click one of the four colour
  dots on the selected row (its own quadrant is the filled one). The todo lands
  on top of its new quadrant and you stay in the list. ⌘Z puts it back where it
  was. A small glass badge rises out of the panel ("↗ Moved to ● Urgent &
  Important"), and VoiceOver gets "Move to …" actions on each row.
- **Export.** **Export…** in the menu-bar menu writes every todo, open and done,
  with its attachments into a folder you pick (`howy.json` plus
  `attachments/<todo id>/<file name>`). A window then shows how many todos and
  attachments were exported, lists any files that couldn't be copied, and has a
  **Show in Finder** button.
- **Import.** **Import…** reads an export folder back in. Howy first shows what
  it found ("Found 87 todos (12 already exist and will be skipped, 2 invalid),
  23 attachments. Import?") and only writes after you confirm. Todos that
  already exist are skipped, existing data never changes, and timestamps are
  kept. A summary lists the counts and one line per problem, with a **Copy**
  button. A file that can't be read, or that comes from a newer Howy, is refused
  and nothing changes.
- **Copy for AI.** Settings has a new **Import Format** section. **Copy for AI**
  puts a description of the import format, with an example, on the clipboard,
  so an AI chat can turn data from another app into a `howy.json` to import.

### Changed

- The Browse footer calls ⌘J / ⌘K "reorder" now, since "move" means another
  quadrant.

## [1.0.0] - 2026-10-07

First release.

### Added

- Menu-bar app with no Dock icon. It can start at login.
- **Quick Add** panel (⌃⌥⇧⌘Space): a Spotlight-style floating panel with a 2×2
  quadrant picker (arrow keys or 1–4), a title, a Markdown note, and ⌘↩ to save.
  It remembers the last quadrant you used.
- **Browse** panel (⌃⌥⇧⌘M): quadrant picker with open counts. You can browse a
  quadrant's todos, edit them, mark them done with `D`, archive them with ⌫, and
  undo with ⌘Z.
- Reorder todos with ⌘↑/⌘↓ (⌘K/⌘J) or by dragging the row grip. The order also
  shows in the widgets.
- Optional one-shortcut mode with a launcher that chooses between New Todo and
  Browse.
- **Edit** panel that looks like Quick Add: change title, note and quadrant, and
  delete with ⌘⌫ after a confirmation.
- Drafts: unsaved quick-entry text and unsaved edits survive Esc, clicking away
  and app restarts.
- Live Markdown styling in notes, with automatic list continuation.
- **Attachments**: paste, drop or pick files. They show as thumbnails, open in
  Quick Look or the default app, and the note reference and thumbnail highlight
  each other. A paperclip marks todos with attachments in lists and widgets.
- **Archive** panel: restore or delete done todos. Archived todos are deleted
  automatically after a period you choose in Settings (1, 3, 7, 14, 30 or 90
  days; 7 by default).
- Done animation: a random emoji with a confetti burst (emoji + confetti, emoji
  only, or off).
- **Matrix widget** (large and extra-large) and **Quadrant widget** (small and
  medium, quadrant chosen per widget). They have interactive checkboxes, and
  deep links open edit, Quick Add for a quadrant, or the archive.
- Menu bar "Add to Quadrant" opens Quick Add straight on the title for the
  quadrant you chose.
- Settings window: shortcut recorders, start quadrant, attachment open mode,
  done animation, archive retention, and start at login.
- App icon.

### Fixed

- Panels no longer close by themselves when the app activates late after opening
  from a widget or the menu.
- Crash from a layout loop in the panel constraints.
- Modals no longer jump when they switch between screens.
