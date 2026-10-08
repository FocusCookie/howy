# Changelog

All notable changes to Howy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
