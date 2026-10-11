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
  add a new todo to that quadrant with **N**, mark done with **D**, undo with **⌘Z**, and reorder with **⌘↑/⌘↓** (or drag).
  In the edit window, **⌘D** saves and marks the todo done.
- **Overview**: press **O** in Browse (or click the button between the
  quadrants) to see all four quadrants side by side. Focus one with **1–4** or
  **⌥1–4**, edit or add (**N**) todos right in their tile, and drag todos
  between quadrants.
- **One-shortcut mode** (optional): a single shortcut opens a small chooser
  between _New Todo_ and _Browse_.
- **Esc** never loses your typing. Unsaved text is kept as a draft, even across
  restarts. **⌘W** closes the Howy panel from any screen.
- **Panel zoom**: **⌘+** / **⌘-** make a panel's text and layout bigger or
  smaller in four steps (100–150 %), and **⌘0** goes back to 100 %. The size is
  remembered.
- **Live Markdown** in notes: headings, bold, lists and links are styled as you
  type, and lists continue when you press ↩.
- **Checklists** in notes: **⇧⌘L** turns the lines you've selected into
  `- [ ]` items, and pressed again it ticks or unticks them. Click a box to
  tick or untick it. Ticked items are crossed out and greyed. **⌘Z** undoes
  either. The key hints show **⇧⌘L checklist** while you're in the note.
- **Links** in notes: paste a web address and a small dialog asks for its
  title. It starts with the site's domain and switches to the page's own title
  once Howy has looked it up (unless you've started typing). **↩** adds the
  link, **Esc** cancels the paste. Paste over selected text and that text
  becomes the link right away. A link shows as a chip with a link icon and its
  title: the cursor steps over it, and the first **⌫** selects it before the
  next deletes it. With the cursor next to a chip a popover shows its address.
  **⌘O** (or **⌘-click**) opens the link, and **⌘E** edits its title and
  address (**⌘⌫** in that dialog turns it back into plain text). ⌘O and ⌘E also
  work on a bare address. In the file the note keeps plain Markdown,
  `[title](url)`.
- **Attachments**: paste or drop screenshots and files into a todo. You get
  thumbnails, and files open in Quick Look.
- A small emoji and confetti burst when you finish something. You can turn it
  off.

### Due dates and reminders

- **Set a due date** with **⌘T** in the editor (or click the clock pill in its
  header), or with **T** on the selected todo in Browse (or click the row's
  clock). A small dialog opens over the panel with one field: type when it's
  due and a live preview shows what Howy understood, for example
  _→ Fri 16 Oct 2026, 10:00 · in 7 days · no time → 9:00_.
  **↩** sets it (only a valid date; on an empty field it keeps the date that's
  set), **Esc** cancels, **⌘⌫** (or _Remove_) removes the date. In the editor
  the date is saved with the todo.
- **What you can type** (English, 24-hour or am/pm times; the **?** button
  or **⇥** shows examples in a small panel beside Howy's: click one, or pick it
  with **↑↓** and **↩**):
  - Relative: `in 30 min`, `in 12h`, `in an hour`, `in 3 days`, `in a week`,
    `in 2 months`. Days, weeks and months keep the current time of day.
  - Days: `today`, `tomorrow` (typos like `tomorow` work), `day after tomorrow`,
    `tonight` / `this evening` (18:00), `tomorrow morning` (9:00), `afternoon`
    (14:00), `evening` (18:00), `noon`.
  - Weekdays: `fri`, `friday`, `this friday`, `wednes` mean the coming one (a
    week later on that same weekday); `next friday` is the one after that.
    `next week` is Monday, `weekend` is Saturday.
  - Dates, day first: `10.10.2026`, `10.10.26`, `24.12.`, `24.12`, `3 nov`,
    `nov 3`, `3rd november 2027`. Without a year it's the next time that date
    comes.
  - Times: `10am`, `10 am`, `2pm`, `10:30pm`, `14:30`, `at 10`. A time on its
    own that has already passed today means tomorrow.
  - `at`, `on`, `by`, `the` and `of` are ignored, so `10.10.2026 at 10am`
    works. A date without a time is due at 9:00 (change it in Settings). Dates
    in the past, impossible times (`25:00`) and words Howy doesn't know are
    refused with a message.
- **In Browse** a dated todo shows a grey clock and a short time (_in 25 min_,
  _16:00_, _Tomorrow 10:00_, _Fri 10:00_, _21 Oct_, or _10 Oct 2027_ in another
  year); an overdue one a red bell
  and _Overdue · 2 h_. The bell wiggles once when the list opens. Hover a label
  for the full date. Due dates never change the order or the quadrant.
- **Notifications** at the due time show the title and quadrant, with **Done**,
  **Snooze 1 h** and **Tomorrow 9:00**. Clicking one opens the todo. Howy asks
  for permission the first time you set a due date. Due dates passed while the
  Mac was asleep or off notify once when it wakes. Completing, archiving or
  deleting a todo cancels its notification (the date is kept), and restoring
  it schedules it again. Without permission everything else still works, and
  Settings shows a link to turn notifications on.

### Desktop widgets

- **Matrix widget** (large and extra-large): all four quadrants as separate
  see-through tiles, without a big header.
- **Quadrant widget** (small and medium): shows one quadrant of your choice.
  Place four of them side by side.
- Tick a checkbox to complete a todo straight from the desktop. Click a title to
  edit it, or click a quadrant label to add a todo to that quadrant.
- A small clock marks todos with a due date; it turns red the moment one is
  overdue.
- Works in light and dark mode and with tinted widget styles.

### Archive

- Done todos go to an archive. You can restore or delete them there.
- The archive empties itself after a period you choose (1–90 days, 7 by
  default).

### Import, export and backups

- **Export…** writes a folder with `howy.json` (every todo, open and done, plus
  its history) and `attachments/<todo id>/<file name>`. **Import…** reads such a
  folder back after a preview. It merges by id: todos that already exist are
  skipped and never changed, but their history events that Howy doesn't have
  yet are added, and events that are already there are skipped, so importing
  the same folder twice changes nothing. The preview and the summary count the
  events (added, skipped, invalid). A history event with a damaged optional
  field is still imported without that field; one with a damaged id, todo id,
  kind or date is skipped. Exports from older Howy versions (format version 1)
  still import.
- **Copy for AI** (Settings → Import & Export) copies a description of the
  format. Paste it into an AI chat with data from another app, and it answers
  with a `howy.json` you can import.
- **Daily backups:** once a day (at launch, and when the day changes while
  Howy runs) Howy writes the same kind of export to
  `~/Library/Group Containers/group.howy/Library/Application Support/Backups/Howy Backup yyyy-MM-dd`
  and keeps the newest 7. A backup is built in a `.partial` folder and renamed
  once it's complete, so a failed run never costs you an existing backup. Only
  complete backups dated today or earlier count and get pruned, and nothing is
  pruned after a backup that couldn't copy an attachment. An empty store isn't
  backed up, so a loss of data never pushes the good backups out. Settings →
  Import & Export → **Show in Finder** opens the folder; import a backup to
  restore it.

### Menu bar and Settings

- The menu has Quick Add, Browse, Archive, _Add to Quadrant_, Import…,
  Export…, Settings… and Quit.
- In Settings you can set the panel size, record your own shortcuts, choose which quadrant new todos
  start on, choose how attachments open, set the done animation, size the
  Overview, set how long
  the archive keeps todos, set the time used for due dates typed without one,
  open the backups folder, and turn on start at login.

All data stays on your Mac (SwiftData in a sandboxed App Group container). Howy
has no sync and no account. It keeps a history of what happens to each todo
(added, done, moved, due date changes, deleted; ids and times only, no titles)
for statistics in a later version. A todo that exists twice shows once. At
launch Howy removes the copies that differ from the most recently changed one
(exact copies stay; they are harmless), and moves attachment folders whose todo
is gone into
`Attachments/.trash` (emptied after 14 days). It never does that for an empty
store, or when more than half of the attachment folders look orphaned.

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
- [`AGENTS.md`](AGENTS.md): project structure and conventions for contributors
  and AI agents
