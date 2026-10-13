# Howy

**A hotkey-driven Eisenhower matrix for the macOS desktop.**

Howy is a small menu-bar app that keeps your todos in the four Eisenhower
quadrants: _Urgent & Important_, _Not Urgent & Important_, _Urgent &
Unimportant_ and _Not Urgent & Unimportant_. You capture and browse todos in
floating panels that appear above everything, like Spotlight or Raycast. Desktop
widgets show your matrix at a glance. Howy has no Dock icon and no main window.
Everything happens from a shortcut.

## What it can do (v2.1.0)

### Floating panels, driven by the keyboard

- **One shortcut, Open Howy**: press **⌃⌥⇧⌘Space** anywhere (change it in
  Settings → Keys). You see the four quadrants with their open counts, starting
  on the quadrant you opened or added to last. Press it again while Howy is
  open and Howy closes, from any screen, like **⌘W**.
- **Add a todo**: **N** on the grid adds one to the highlighted quadrant, and
  **N** in a list to that quadrant. Type a title, add an optional Markdown
  note, and save with **⌘↩**. Saving or **Esc** brings you back to where you
  were. **⇧⇥** from the title reaches a small quadrant picker if you want
  another quadrant.
- **Browse**: open a quadrant with **1–4** or **↩**, go through its todos with
  **↑/↓**, edit with **↩**, mark done with **D**, undo with **⌘Z**, and reorder
  with **⌘↑/⌘↓** (or drag). **M** or **⌘1–4** moves a todo to another quadrant.
  In the editor, **⌘D** saves and marks the todo done.
- **Overview**: press **O** on the grid or in a list (or click the button
  between the quadrants) to see all four quadrants side by side. Focus one with
  **1–4** or **⌥1–4**, or move to the tile beside it with **←/→**; edit or add
  (**N**) todos right in their tile, and drag todos between quadrants.
- **Vim keys** work next to the arrows wherever there's nothing to type into:
  **h j k l** on the grid and in the move picker, **j k** in a list and in the
  archive, **h l** in a note's attachments, and in the Overview **j k** inside a
  tile and **h l** to the tile beside it. In text fields and dialogs the letters are just typing.
- **?** on the grid, in a list, in the Overview or in the archive opens
  Settings → Keys, a reference of every key on every screen.
- **Esc** never loses your typing. Unsaved text is kept as a draft, even across
  restarts. **⌘W** closes Howy from any screen.
- **Panel zoom**: **⌘+** / **⌘-** make a panel's text and layout bigger or
  smaller in four steps (100–150 %), and **⌘0** goes back to 100 %. The size is
  remembered.
- **Live Markdown** in notes: headings, bold, lists and links are styled as you
  type, and lists continue when you press ↩. A fenced code block (` ```json `)
  sits on one grey box and its code is coloured by the language after the
  fence: JSON, Swift, JavaScript / TypeScript, Python, shell and YAML (other
  languages get strings, numbers and comments).
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
  thumbnails, and files open in Quick Look (or in their app, see Settings →
  General). Drop files on the strip under the note, or click it, to attach
  them without putting them in the note. A file can be up to 100 MB; a bigger
  one is refused with a message, because attachments sync through iCloud.
- **Attachment chips** in notes: an attachment in the note shows as a chip like
  a link, with a paperclip (a file) or a photo (an image) and its title. Paste
  or drop one file into the note and an **Add Attachment** dialog asks for the
  chip's title (the file name without its extension, or empty with
  "Screenshot" for a pasted screenshot). **↩** puts the chip in at the cursor,
  **Esc** cancels and attaches nothing. Paste a file over selected text on one
  line and that text becomes the title right away. Several files at once go in
  with their names, on one line. In the attachments, **I** inserts the selected
  one where the cursor was in the note (shown there as a wide, steady accent
  caret), and you can also drag a thumbnail onto the note; dragging it out to
  Finder copies the file. The chips of the selected or hovered attachment are
  highlighted. On a chip, a popover shows the file name; **⌘O** (or
  **⌘-click**) opens it, **⌥⌘O** the other way, and **⌘E** edits the title
  (**⌘⌫** there removes the chip and, for its last chip, asks whether to
  delete the attachment too: **Y** yes, **N** or **↩** no, so ↩ never deletes
  by accident; **⌘Z** after a yes brings the attachment back). **⌫⌫** and
  **⌘Z** take only the chip out; the attachment stays. In the file the note keeps plain Markdown, `[title](file)`
  or `![title](image)`.
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
    works. A date without a time is due at 9:00 (change it in Settings →
    General). Dates in the past, impossible times (`25:00`) and words Howy
    doesn't know are refused with a message.
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
  edit it, or click a quadrant label to open the editor for a new todo in that
  quadrant.
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
- **Import…** and **Export…** are in the menu and in Settings → Data.
- **Copy for AI** (Settings → Data) copies a description of the
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
  Data → **Show in Finder** opens the folder; import a backup to
  restore it.

### Menu bar and Settings

- The menu has Open Howy (with its shortcut), Archive, _Add to Quadrant ▸ 1–4_
  (opens the editor for a new todo in that quadrant), Import…, Export…,
  Settings… and Quit.
- Settings has five tabs in its toolbar. The window takes each tab's size and
  opens on the tab you used last.
  - **General**: start at login, how attachments open, the time used for due
    dates typed without one (and a link to turn notifications on when they're
    off).
  - **Keys**: the Open Howy shortcut (with _Restore Default_), and below it a
    reference of every key, screen by screen.
  - **Appearance**: the panel size, the Overview's size (with a preview), and
    the done animation.
  - **iCloud**: the sync status line and what syncing does.
  - **Data**: how long the archive keeps done todos, Import… and Export…, Copy
    for AI, and the daily backups' folder.

### iCloud sync

- Todos, their attachments, their history and the archive period sync between
  your Macs through iCloud (your private iCloud database, no sharing). It's always on while you're
  signed in to iCloud; without an account Howy works locally.
- Changes from another Mac arrive by push, and Howy also checks for them when a
  panel opens, after the Mac wakes and every 5 minutes while it runs. So a
  change can take a few minutes to show up.
- Attachments sync with their todo. The files are stored in Howy's data (and
  in iCloud). A Mac writes a local copy of a file only when you open that todo
  for editing (in the background; the thumbnail shows a spinner until it is
  there), or when the file is added on that Mac. Export… and the daily backups
  read the files straight from Howy's data and make no local copies. Saving a
  todo only deletes the attachments you removed in that edit, so a file
  another Mac added meanwhile stays. Attachments added before this version
  show at once and move into Howy's data when the new version starts, one todo
  at a time (a file Howy can't read holds back only its own todo), and again
  after later syncs; then they sync too. Large files take longer to arrive and
  count against your iCloud storage.
- Drafts, the last quadrant, panel size and the other display settings stay
  per Mac.
- The widget shows what the app last received; it updates while Howy runs.
- **Signing out of iCloud, switching accounts or turning off iCloud for Howy
  removes the todos from this Mac** (Apple's behaviour). Signing back in
  downloads them again, but changes that hadn't uploaded yet are lost. Howy
  tells you with a notification when it sees this happen (also at the next
  launch if it happened while Howy wasn't running), and the daily backup is the
  safety net (Settings → Data).
- **Settings → iCloud** shows one status line: checking, syncing, up to date
  (with when it last synced), offline, waiting for iCloud, not signed in or
  iCloud off for Howy (Howy then works on this Mac only), or a sync error with
  a short reason. In Low Power Mode, macOS delays background work, so while
  sync otherwise works the line adds "Low Power Mode is on, so sync may be
  delayed."
- **Notifications** come once per problem, and clicking one opens Settings → iCloud
  with the status line highlighted: the todos were removed from this Mac (signed out, iCloud off
  for Howy, another account, or Howy's data deleted from iCloud), iCloud
  storage is full, or sync has failed for over an hour. Being offline or a
  short hiccup at iCloud never notifies. Storage-full and failing notices don't
  repeat within a day. If notifications were never allowed, the first notice
  asks for permission.
- **Low Power Mode** turning on notifies too ("Sync may be delayed"), each
  time it turns on while Howy syncs with a signed-in iCloud account, and Howy
  removes the notice when it turns off. It doesn't
  notify when Howy starts with Low Power Mode already on, and it only shows if
  notifications are already allowed (it never asks for permission).
- Editing the same todo on two Macs at the same moment can lose one of the
  two edits.
- Howy waits until it has received the changes from iCloud before it runs its
  cleanups or empties the archive, so a Mac that joins with an empty or older
  store never deletes anything first.

Howy keeps its data in SwiftData in a sandboxed App Group container, and syncs
it only to your own iCloud account. It keeps a history of what happens to each todo
(added, done, moved, due date changes, deleted; ids and times only, no titles)
for statistics in a later version. A todo that exists twice shows once. Howy
removes the copies that differ from the most recently changed one (exact copies
stay; they are harmless), removes todos that were deleted on another Mac, and
moves attachment folders whose todo is gone into
`Attachments/.trash` (emptied after 14 days). It never does that for an empty
store, or when more than half of the attachment folders look orphaned. The
synced attachments of a todo that is gone are removed an hour after the todo's
`deleted` history event (deleting a todo leaves its attachments until then, so a
delete that races an edit on another Mac doesn't cost the todo its files), under
the same two limits (the limit on a share of todos applies when more than 3
todos have attachments). Attachments of a todo that has history but no `deleted`
event, or that hasn't arrived yet, are left alone, and so are attachments that
Howy stored without ever creating their todo (a crash in between) for 30 days,
after which they are removed.

## Requirements

- macOS 27 or later
- An iCloud account for sync (optional)
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
