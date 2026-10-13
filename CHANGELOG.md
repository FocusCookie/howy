# Changelog

All notable changes to Howy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.2.0] - 2026-10-13

### Added

- **Attachment chips** in notes: references to attachments show as chips like
  links, with a paperclip for a file and a photo for an image. They behave as
  one character (the cursor steps over them, the first ⌫ selects one). Notes you
  already have get chips by themselves; the Markdown stays the same.
- **Add Attachment dialog**: pasting or dropping one file into the note asks for
  the chip's title first; Esc attaches nothing. Pasted over a one-line
  selection, the selection becomes the title without a dialog.
- **I in the attachments** inserts the selected one into the note where the
  cursor was, shown as a ghost caret while you're in the attachments. Dragging
  a thumbnail onto the note does the same at the drop point; dragging it to
  Finder copies the file.
- **⌘O / ⌥⌘O / ⌘-click** on an attachment chip opens it, also in the Overview's
  tiles; **⌘E** edits its title (Edit Attachment), where ⌘⌫ removes the chip and
  asks "Also delete the attachment?" when it was the last one.
- The chips of the selected or hovered attachment are highlighted, and a popover
  on a chip shows the file name (with a thumbnail for an image).
- **h l** select in a note's attachments, like ← →.

### Changed

- Pasted or dropped files go into the note inline at the cursor, several on one
  line, instead of each on a line of its own.
- ⌘Z takes back an added attachment chip in one step and keeps the
  attachment, the same as ⌫⌫.
- In "Also delete the attachment?", **↩** now answers No (the safe default);
  **Y** is Yes, **N** is No. ⌘Z after a Yes brings the attachment back.

### Fixed

- Dragging an attachment out of the strip to Finder always copies the file; it
  can no longer move it out of Howy.
- A file pasted or dropped onto the note is copied when you paste it, so the
  dialog still works if the original (a screenshot thumbnail, say) goes away.
- Removing an attachment with ⌫ in the strip no longer leaves a double space
  where its chip was.
- The strip no longer lights up as a drop target for its own thumbnails.
- A note changed from outside (an undo, a removed chip) keeps the cursor
  where it was instead of jumping to the end.
- Chips keep their icons when the note starts with a chip (they were drawn at
  almost zero size).
- The popover under a chip (links too) is no longer cut off at the card's
  edge or covered by the attachment strip: it floats above the panel.

## [2.1.0] - 2026-10-13

### Added

- **N on the quadrant grid** opens the editor for a new todo in the highlighted
  quadrant. Saving or Esc brings you back to the grid with that quadrant still
  highlighted. The grid's key hints show it.
- **Vim keys** next to the arrows: h j k l on the quadrant grid and in the
  move picker, j k in a quadrant's list and in the archive. In the Overview,
  j k move inside a tile, and h l (and now ← →) move to the tile beside it;
  ↑ ↓ never leave a tile. Text fields and dialogs keep the letters as typing.
- **?** on the quadrant grid, a list, the Overview or in the archive opens
  Settings → Keys. In text fields and dialogs "?" is still just typed. The
  grid's key hints show it.
- **Keys reference** in Settings → Keys: every key of every screen (grid, list,
  move picker, Overview, archive, editor, attachments, due-date and link
  dialogs, panel zoom), with the vim keys beside the arrows, under the Open
  Howy shortcut. A test checks it against the keys Howy really handles, so it
  stays right.
- **Import… and Export…** buttons in Settings → Data, next to Copy for AI and
  the daily backups (the menu entries stay).

### Changed

- **One global shortcut: Open Howy** (default ⌃⌥⇧⌘Space). It opens the quadrant
  grid; pressed while Howy is open, it closes Howy from any screen, like ⌘W, and
  keeps an unsaved todo as a draft. It replaces the Quick Add, Browse and
  one-shortcut-mode shortcuts: on the first launch Open Howy takes over your
  Quick Add shortcut (or your one shortcut, if you used one-shortcut mode); the
  Browse shortcut (⌃⌥⇧⌘M) is gone. Record it in Settings → Keys, where
  "Restore Default" brings back ⌃⌥⇧⌘Space.
- **Settings has tabs**: General, Keys, Appearance, iCloud and Data in a
  toolbar, like other Mac apps' settings, instead of one wide window. The
  window takes each tab's size and opens on the tab you used last. A click on
  a sync notification opens the iCloud tab with the status line highlighted.
- The grid opens on the quadrant you opened or added to last, instead of
  always on Do First.
- The menu's "Browse" is now "Open Howy" and shows the shortcut.
- "Add to Quadrant ▸ 1–4" in the menu and a widget's quadrant label open the
  editor for a new todo in that quadrant straight away; Esc closes it and keeps
  the draft. ⇧⇥ from the title still reaches the quadrant picker. Old
  `howy://quick-add` links without a quadrant open the quadrant grid.

### Removed

- The Quick Add panel and its quadrant-choosing first step, and the menu's
  "Quick Add" item. New todos start from the grid or list (N), "Add to
  Quadrant" or a widget.
- One-shortcut mode with its New Todo / Browse chooser and the "Selected first"
  setting, and the "New Todos → Start on" setting.

## [2.0.0] - 2026-10-12

### Added

- **iCloud sync between your Macs.** Todos, their history and the archive
  period sync through your private iCloud database. It's always on while you're
  signed in to iCloud; without an account Howy works locally as before. Changes
  arrive by push, and Howy also checks for them when a panel opens, after wake
  and every 5 minutes, so a change can take a few minutes to show up on the
  other Mac. Attachments don't sync yet.
- **iCloud status in Settings.** A new iCloud section shows one line: syncing,
  up to date (and when it last synced), offline, not signed in or iCloud off
  for Howy (local only, not an error), or a sync error with a short reason.
- **Sync notifications**, once per problem; clicking one opens Settings at the
  iCloud line. Howy tells you when the todos were removed from this Mac
  (signed out, iCloud turned off for Howy, another iCloud account, or Howy's
  data deleted from iCloud) and points to the daily backups, when iCloud
  storage is full, and when sync has failed for over an hour. Being offline or
  a brief network problem never notifies.

### Changed

- **Your todos now belong to your iCloud account.** Signing out of iCloud,
  switching accounts or turning off iCloud for Howy removes the todos from this
  Mac (Apple's behaviour); signing back in downloads them again, but changes
  that hadn't uploaded yet are lost. Howy notifies you when this happens, and
  the daily backup is the safety net.
- A Mac that joins with an empty or older store doesn't clean up or empty the
  archive until it has received the changes from iCloud. Todos deleted on another Mac are removed here too, unless they were
  edited after the delete.
- Debug builds use their own store, backups and attachments folders
  (`Howy-Debug.store`, `Backups-Howy-Debug/`, `Attachments-Howy-Debug/`).

## [1.8.0] - 2026-10-11

### Added

- **Daily backups.** Once a day Howy exports everything (todos, attachments
  and history) to
  `~/Library/Group Containers/group.howy/Library/Application Support/Backups/`,
  one folder per day named `Howy Backup yyyy-MM-dd`. It keeps the newest 7 and
  deletes older ones (only complete backups dated today or earlier count). A
  backup is written to a `.partial` folder and renamed when complete, so a
  failed run keeps your existing backups. The backup runs at launch and when the day changes while
  Howy is running. An empty store isn't backed up, so the older backups survive
  if the data is ever lost. **Settings → Import & Export → Show in Finder**
  opens the folder; to restore, choose a backup in **Import…**.
- **History.** Howy now records what happens to each todo: added, done,
  restored, moved, due date set, changed, snoozed or removed, deleted. It
  stores only ids, quadrants and times, never titles or notes, and nothing uses
  it yet; it's the basis for statistics later. Existing todos get their history
  from their created and done dates when Howy first starts.

### Changed

- **Exports include the history.** Export writes format version 2, which adds
  an `events` list to `howy.json`. Importing adds history events Howy doesn't
  have yet, also for todos that already exist, and skips the rest, so importing
  the same export twice changes nothing. The import preview and summary count
  the events. A damaged optional field of an event is dropped with a note; the
  event is skipped only when its id, todo id, kind or date is damaged. A
  version 2 file without `events` gets a note. Older exports (version 1) still
  import as before.
- **Tidying at launch.** Howy removes duplicate copies of a todo (keeping the
  most recently changed one) and moves attachment folders whose todo no longer
  exists to `Attachments/.trash`, which it empties after 14 days. It does
  nothing for an empty store, or when more than half of the folders look
  orphaned. The daily backup runs before this cleanup.
- The check for a missing history runs once per Mac, not on every start, so
  todos that arrive before their history don't get made-up events.
- Settings' **Import Format** section is now **Import & Export**.
- **New bundle ID and App Group.** The app is now `lueddemann.howy` (widget
  `lueddemann.howy.widgets`) and stores its data in the `group.howy` App Group.

## [1.7.0] - 2026-10-11

### Added

- **Due dates and reminders.** A todo can have one due date.
  - **⌘T** in the editor (or the clock pill in its header) and **T** in Browse
    (or a row's clock) open a small dialog with one field and a live preview.
    **↩** sets the date, **Esc** cancels, **⌘⌫** removes it; an empty field
    keeps the date that's set.
  - Type it in words: `in 30 min`, `in a week`, `tomorrow 10am`, `tonight`,
    `fri`, `next friday`, `next week`, `weekend`, `24.12.`,
    `10.10.2026 at 10am`, `3 nov 5pm`, `14:30`, `noon`… A date without a time
    means 9:00 (a new Settings choice). The **?** button (or **⇥**) shows
    examples in a panel beside Howy's; click one or pick it with **↑↓** and
    **↩**.
  - Browse shows a grey clock and a short time on dated todos, and a red bell
    with _Overdue · 2 h_ on late ones; the bell wiggles when the list opens.
  - A notification at the due time with **Done**, **Snooze 1 h** and **Tomorrow
    9:00**; clicking it opens the todo. Permission is asked the first time you
    set a due date, and Settings links to System Settings when notifications are
    off. Dates that passed while the Mac slept notify on wake.
  - The widgets show a small clock on dated todos, red once overdue, and update
    at that moment.
  - Export and import keep due dates (`"due"` in `howy.json`; older exports
    still import).

### Changed

- The data store moves to schema version 2 (an optional due date per todo).
  Existing todos are migrated automatically and keep everything.
- A long title in the editor wraps onto up to three lines instead of scrolling
  out of view.

### Fixed

- The editor's title no longer jumps a few pixels when it gets or loses focus.

## [1.6.0] - 2026-10-09

### Added

- **Links in notes.** Paste a web address into the note and a small dialog asks
  for its title.
  - The title starts as the site's domain (`github.com`) and is replaced by the
    page's own title once Howy has fetched it, unless you've started typing.
    **↩** adds the link, **Esc** cancels the paste. An empty title pastes the
    plain address.
  - **Paste over selected text** and that text becomes the link, no dialog.
  - A link shows as a **chip** with a link icon and its title; the note still
    stores Markdown, `[title](url)`. The cursor steps over a chip like one
    character, and the first **⌫** (or **⌦**) next to one selects it, the next
    deletes it. Click a chip to put the cursor after it.
  - With the cursor on a chip, a **popover** shows its address with **Open** and
    **Edit**. **⌘O** (or **⌘-click**) opens the link in your browser, **⌘E**
    edits its title and address; **⌘⌫** in that dialog turns it back into plain
    text. Both keys also work on a bare address, so ⌘E gives one a title. The
    key hints show them while the cursor is on a link.
- Howy now has the network permission (outgoing connections only) to fetch a
  pasted link's page title.

## [1.5.0] - 2026-10-09

### Added

- **Checklists in notes.** Markdown task items (`- [ ] todo`, `- [x] done`) get
  a dimmed box with an accent-coloured tick, and a ticked item's text is crossed
  out and greyed.
  - **⇧⌘L** in the note turns the selected lines into checklist items (a list
    item keeps its marker, `1.` included). Pressed on items, it ticks them, or
    unticks them when they're all ticked already. On an empty line it starts a
    new `- [ ] ` item.
  - **Click a box** to tick or untick it. The pointer turns into a hand over a
    box and the box gets a soft highlight; the cursor stays where it was.
  - **⌘Z** undoes either in one step. The key hints show **⇧⌘L checklist** while
    you're in the note.

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
  zooms in, **⌘-** zooms out and **⌘0** goes back to 100 %. There are four steps
  (100, 115, 130 and 150 %); 100 % is the size you know and the smallest. The
  keys work in every panel, also while you type a title or a note, and Howy
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
    where it lands, dropping on a quadrant's header puts it on top, and ⌘Z takes
    it back.
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
  deleted for good only from the archive, and the edit window's Delete button is
  gone.

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
  puts a description of the import format, with an example, on the clipboard, so
  an AI chat can turn data from another app into a `howy.json` to import.

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
