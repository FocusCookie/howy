# Howy

**A hotkey-driven Eisenhower matrix for the macOS desktop.**

Howy is a small menu-bar app that keeps your todos in the four Eisenhower
quadrants: _Urgent & Important_, _Not Urgent & Important_, _Urgent &
Unimportant_ and _Not Urgent & Unimportant_. You capture and browse todos in
floating panels that appear above everything, like Spotlight or Raycast. Desktop
widgets show your matrix at a glance. Howy has no Dock icon and no main window.
Everything happens from a shortcut.

## What it can do (v1.0.0)

### Floating panels, driven by the keyboard

- **Quick Add**: press **⌃⌥⇧⌘Space** anywhere. Pick a quadrant (arrow keys or
  **1–4**), type a title, add an optional Markdown note, and save with **⌘↩**.
- **Browse**: press **⌃⌥⇧⌘M**. You see the four quadrants with their open
  counts. Open a quadrant, go through its todos with **↑/↓**, edit with **↩**,
  mark done with **D**, undo with **⌘Z**, and reorder with **⌘↑/⌘↓** (or drag).
- **One-shortcut mode** (optional): a single shortcut opens a small chooser
  between _New Todo_ and _Browse_.
- **Esc** never loses your typing. Unsaved text is kept as a draft, even across
  restarts.
- **Live Markdown** in notes: headings, bold, lists and links are styled as you
  type, and lists continue when you press ↩.
- **Attachments**: paste or drop screenshots and files into a todo. You get
  thumbnails, and files open in Quick Look.
- A small emoji and confetti burst when you finish something. You can turn it
  off.

### Desktop widgets

- **Matrix widget** (large and extra-large): all four quadrants as separate
  see-through tiles, without a big header.
- **Quadrant widget** (small and medium): shows one quadrant of your choice.
  Place four of them side by side.
- Tick a checkbox to complete a todo straight from the desktop. Click a title to
  edit it, or click a quadrant label to add a todo to that quadrant.
- Works in light and dark mode and with tinted widget styles.

### Archive

- Done todos go to an archive. You can restore or delete them there.
- The archive empties itself after a period you choose (1–90 days, 7 by
  default).

### Menu bar and Settings

- The menu has Quick Add, Browse, Archive, _Add to Quadrant_, Settings… and
  Quit.
- In Settings you can record your own shortcuts, choose which quadrant new todos
  start on, choose how attachments open, set the done animation, set how long
  the archive keeps todos, and turn on start at login.

All data stays on your Mac (SwiftData in a sandboxed App Group container). Howy
has no sync and no account.

## Requirements

- macOS 27 or later
- Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build it

## Building

```sh
xcodegen generate
xcodebuild -project Howy.xcodeproj -scheme Howy -configuration Release \
  -derivedDataPath build/release build
open build/release/Build/Products/Release/Howy.app
```

To sign it with your own Apple ID, change `DEVELOPMENT_TEAM` in `project.yml`. A
free Personal Team is enough.

Run the tests:

```sh
cd Packages/HowyCore && swift test
```

## Project docs

- [`CHANGELOG.md`](CHANGELOG.md): release history
- [`docs/PRD.md`](docs/PRD.md): product requirements and design decisions
- [`AGENTS.md`](AGENTS.md): project structure and conventions for contributors
  and AI agents
