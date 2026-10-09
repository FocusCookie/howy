# Changelog

All notable changes to Howy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
