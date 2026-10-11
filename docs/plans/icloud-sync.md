# Plan: iCloud sync (and the road to iOS)

Status: agreed 2026-10-11. Branch: `feat/icloud-sync`.

## Goal

Sync Howy's todos between the user's own devices through iCloud. Start Mac ↔
Mac; every data decision must also work for the later iOS app. Record usage
events now so a stats screen can come later.

## Decisions

### Basics

- **Devices:** Mac ↔ Mac now, built and tested so iOS can reuse it unchanged.
- **Engine:** SwiftData's built-in CloudKit sync (`cloudKitDatabase: .private`).
  Conflicts resolve last-write-wins per field. Accepted for a single user.
- **Database:** CloudKit **private** database, only the signed-in user's own
  iCloud account. No sharing.
- **Container:** `iCloud.lueddemann.howy`. Permanent; the iOS app uses the same.
- **On/off:** always on when signed in to iCloud. No toggle.
- **Not signed in:** Howy works locally. Settings shows "Not signed in to
  iCloud". Sync starts after sign-in. Test by hand whether todos created before
  sign-in get uploaded (Apple doesn't document it).
- **Existing data:** only this Mac has real todos. It uploads them, and every
  other device starts empty. Backup already exported.

### What syncs

| Data                                                     | Syncs?                                 |
| -------------------------------------------------------- | -------------------------------------- |
| Todos                                                    | Yes (SwiftData + CloudKit)             |
| `TodoEvent` log                                          | Yes                                    |
| Archive retention setting                                | Yes, via iCloud key-value store        |
| Attachments                                              | Not yet. PR 3, before the iOS app      |
| Drafts, last quadrant, done animation, panel size, attachment open mode, launcher choice | No, they stay per device in `UserDefaults` |

Archive retention has to be shared. If it differed between devices, the device
with the shortest period would delete archived todos everywhere.

### Schema v3

- Freeze the current `Todo` as `HowySchemaV2.Todo`. The live `Todo` becomes v3.
- CloudKit rules: drop `@Attribute(.unique)` on `id`, and give every
  non-optional attribute a default value.
- New `updatedAt: Date`, set by every write.
- New model **`TodoEvent`**, append-only, with no relationship to `Todo`:
  - Fields: `id`, `todoID`, `kind`, `date`, plus small values (quadrant
    from/to, due delta).
  - Kinds: created (with quadrant), completed, reopened, moved (from → to),
    due set / changed / snoozed / removed, deleted. Title and note edits are
    **not** recorded.
  - Never stores titles or notes, only IDs, quadrants and times.
  - Kept forever. Archive purge and todo deletion leave events alone.
- Migration v2 → v3 (and v1 → v3). Backfill `created` and `completed` events
  from existing `createdAt` and `completedAt`.

### Duplicates

Todo IDs are UUIDs, so duplicates only come from edge cases such as importing
the same file on two Macs before they sync. A cleanup pass groups todos (and
events) by `id` and keeps the todo with the newest `updatedAt`. It runs at
launch and after remote changes, on a background context.

### Attachments until PR 3

- Other devices simply don't show attachments.
- **Orphan cleanup:** at launch and after remote changes, delete attachment
  folders whose todo no longer exists, for example because it was deleted on
  another device.

### Remote changes

When a remote change arrives, the app:

- reloads widget timelines and the open UI
- rebuilds the due-date notification schedule
- runs the duplicate and orphan cleanups

Due notifications fire on every device, like Reminders. Snoozing on one device
moves the due date everywhere.

Accepted: the widget can't receive changes itself, so it can be stale while
Howy isn't running. Howy runs from login.

### Sign-out and the safety net

Apple's documented behaviour, from Apple staff on the developer forums: signing
out, switching account, or switching Howy off under "Saved to iCloud" **wipes
the local store**, and there is no API to prevent it. Signing back in to the
same account downloads everything again. Changes that hadn't uploaded yet are
lost.

Safety net: a **daily automatic export** into the App Group container, outside
the synced store, keeping the last 7. The export format includes events and
gets a new format version. Old export files still import.

### Status and errors

- **Settings:** one status line: syncing / up to date / not signed in / sync
  error.
- **Notifications:** a macOS notification for real problems. Clicking it opens
  Settings at the sync line. It fires once per incident, for:
  - signed out or iCloud turned off for Howy, so local data was removed
  - iCloud storage full
  - CloudKit schema missing (Production not deployed)
  - sync failing continuously for more than an hour

  Being offline or a brief network failure never notifies.

### CloudKit environments

- **Debug builds:** Development environment. Safe to reset.
- **Release builds:** Production, via the
  `com.apple.developer.icloud-container-environment = Production` entitlement.
- **Before the first Release build with sync:** deploy the schema in CloudKit
  Console (icloud.developer.apple.com → container → Deploy Schema Changes).
  Production schema changes are additive only.
- **Verify** the built app's entitlements with
  `codesign -d --entitlements - Howy.app`, and confirm a Release build really
  syncs. One developer reported that it didn't for them.

## Delivery

### PR 1 → 1.8.0: schema v3, events, cleanups, backups (no iCloud)

- [x] Schema v3 (`HowySchemaV2` frozen, `.unique` dropped, defaults,
      `updatedAt`) and migration plan. Tests: v1 and v2 stores open under v3
      with data intact.
- [x] `TodoEvent` model, with `TodoStore` writing events for every listed kind
      in the same save. Tests per kind.
- [x] Event backfill during migration. Test.
- [x] Duplicate cleanup. Test.
- [x] Orphaned-attachment cleanup. Test.
- [x] Export/import includes events, with a new format version that still reads
      old files. Tests.
- [x] Daily automatic export, keeping the last 7. Test with `FakeClock`.
- [x] README, CHANGELOG and flow doc comments.

Ship it on its own, so the migration runs on real data before iCloud is
involved.

### PR 2 → 2.0.0: iCloud sync

A major version: data now belongs to the iCloud account, and sign-out removes
it from the Mac. The release notes must say so clearly.

- [x] iCloud capability with CloudKit and container `iCloud.lueddemann.howy`,
      in `project.yml`, for the app only (the widget doesn't mirror; see
      "Widget store: `.none`").
- [x] Debug uses Development; Release uses Production through the entitlement.
- [x] `TodoStore` with `cloudKitDatabase: .private(…)`.
- [x] Remote-change handling: widgets, UI, notifications, cleanups.
- [x] Archive retention through `NSUbiquitousKeyValueStore`.
- [ ] Account status (`CKContainer.accountStatus` and `CKAccountChanged`),
      the Settings status line, and error notifications.
- [ ] CloudKit Console steps written down. Schema deployed to Production.
- [ ] Manual tests on two Macs:
  - first upload
  - sign-in after local use
  - sign-out wipe and restore
  - an edit on both Macs at once
  - remote delete with attachments
  - a Release build syncing in Production
- [ ] From the PR 1 reviews, before turning on `.private`:
  - [x] One `ModelContainer` per process. `SharedContainer.process` builds the
        on-disk container once (behind a `Mutex`; a failed build is retried)
        and every `TodoStore.shared()` and `StoreMaintenance` run uses it. Each
        `TodoStore` gets its own `ModelContext`, so a store made now still
        reads what the widget wrote. The sync setting is `StoreSync`: the app
        calls `TodoStore.configureSharedSync(_:)` at launch (`.local` for now;
        Phase 3b flips it to `.iCloud(containerIdentifier:
        StoreSync.containerIdentifier)`), and the widget never calls it, so it
        stays `.local`. See "Widget store: `.none`" below.
  - [x] Duplicate cleanup across devices. Fully identical rows (every stored
        value equal, dates to the millisecond) are never deleted; reads collapse
        them by id and writes copy the survivor's values to every row in the same
        save, so they stay identical. Rows that differ resolve by a total order
        over the stored values only (`Todo.prefers(_:over:)`,
        `TodoEvent.prefers(_:over:)` in `DuplicateRules.swift`), and the cleanup
        deletes every row whose values aren't the survivor's. Events: the same.
        Tests in `SyncSafeDuplicateTests`, including both insertion orders in two
        stores per differing field.
  - [x] Don't run the duplicate cleanup while a remote import is still in flight.
        (Phase 3b: `SyncGate`.)
  - [ ] Test switching an existing v3 store (migrated from v1/v2) from `.none` to
        `.private`. (Phase 3b.)

#### Widget store: `.none`

Decision: the app mirrors, the widget opens the same store file with
`cloudKitDatabase: .none`.

- Apple's TN3164 ("Debugging the synchronization of
  NSPersistentCloudKitContainer", section "Avoid synchronizing a store with
  multiple persistent containers") says an app and its extension must not both
  mirror one shared store, even from different processes, and recommends
  "having the app in charge of the synchronization". A DTS engineer repeats it
  for a widget in developer forums thread 776628 ("I'd like to suggest against
  doing that"). The same technote warns about several mirroring containers on
  one store inside one process, which is why the container is now built once.
- A non-mirroring opener is safe as long as it keeps persistent history on:
  mirroring exports from the store's history, and a write made without history
  would be missed. SwiftData records history for every `DefaultStore` with no
  option to turn it off ("Fetching and filtering time-based model changes":
  history lets an app see "changes made by another process such as a Widget or
  App Intent"), so the widget's `.none` writes (the checkbox,
  `CompleteTodoIntent`) land in the history the app's mirroring reads.
- Howy never deletes history, so nothing purges transactions the mirroring
  still needs.
- To check by hand in Phase 3b: tick a todo in the widget while Howy runs and
  while it doesn't, and confirm the other Mac gets it (the export may only run
  on Howy's next launch or remote-change notification).
- Accepted, as before: the widget doesn't receive remote changes itself; it
  shows what the app last imported.

#### Phase 3a fix round (from the reviews)

- Dates are stored at whole milliseconds since 1970 (`Date.wholeMilliseconds`,
  applied in the `Todo`/`TodoEvent` initialisers, the clock, and every computed
  or user-given date in `TodoStore`). The result is moved up to the first float
  that truncates to the same millisecond, so rounding and truncating
  conversions agree. The duplicate key is milliseconds since 1970, to the
  nearest. Rows already on disk keep their sub-millisecond values (see the
  checklist below).
- `mirrorSurvivor` copies only the fields a write changed, compared by that
  key, so a twin isn't rewritten for nothing and doesn't lose a newer value of a
  field the write didn't touch. A twin that would still beat the survivor gets
  every value.
- The sync setting is chosen in `HowyApp.init()` (the earliest app code, before
  the delegate and any `howy://` open); the result is asserted and logged.
- All containers other than through `StoreSync` pass `cloudKitDatabase: .none`.
- The once-only event self-heal is skipped for a store that mirrors.
- Fewer scans: repeated ids once per `openSnapshots()`, none for an empty fetch,
  only the fetched ids for events, id-first duplicate cleanup.

#### Phase 3b checklist (from the 3a reviews)

- [x] **SyncGate** before any destructive maintenance (duplicates, archive
      purge, orphan trash) and the daily backup. Require all of: the first
      import since launch is done, no import or export in flight, and a quiet
      period of about 30 s. Re-run the cleanups after each successful import.
      The purge also waits until the iCloud key-value store (KVS) retention
      value is known.
- [x] **Debug and Release stores** use different CloudKit environments, so use
      a separate store file per configuration (or keep Debug on `.local`), to
      avoid uploading real data to the wrong environment.
- [x] **Widget entitlements:** the widget gets NO iCloud, KVS or aps
      entitlements.
- [x] **App entitlements:**
  - app: `icloud-container-identifiers`, `icloud-services` CloudKit,
    `ubiquity-kvstore-identifier`, `aps-environment`
  - Release only: `icloud-container-environment = Production`, via a
    per-configuration entitlements file
  - verify with `codesign -d --entitlements -`
- [x] **Failed `.iCloud` container build:** fall back to `.local` for that run,
      show "sync unavailable", and don't retry the build on every `shared()`
      call on the main actor.
- [x] **Remote changes:** observe
      `NSPersistentCloudKitContainer.eventChangedNotification`
      (setup/import/export, extracting plain values off the notification) and
      use it for the gate and the status line. After an import, reload widgets,
      rebuild the due notifications and refresh the open UI.
- [ ] **Account (Phase 3c):** observe `CKAccountChanged` and check `accountStatus`. Detect
      a wipe or account switch with a remembered identity token, and treat
      `userDeletedZone` as a wipe.
- [ ] **CKError matrix (Phase 3c):** decide which errors are silent and which notify
      (quota, schema missing in Production, sync failing for over an hour).
- [x] **KVS:** seed the shared value from the local one on first iCloud launch.
- [x] **Existing rows keep sub-millisecond dates** written before 3a. Quantize
      them once (a one-time pass on a background context) before the first
      upload, or a truncating or rounding CloudKit round trip can still shift
      them by a millisecond.
- [ ] **Hand tests:**
  - a widget tick reaches the other Mac, with Howy running and not running
  - a twin row on two Macs leads to nothing removed
  - a concurrent edit on both Macs
  - a delete while the other Mac edits
  - a migrated v1 or v2 store switching from `.none` to `.private`
  - before deploying the schema, exercise every event kind and optional field
    in Debug
  - a row synced to the other Mac compares identical to its original, e.g. the
    backfilled events (same derived ids on every Mac): after a sync the cleanup
    must report nothing removed
- [x] **Known gap: a delete can be resurrected.** A remote twin arriving after a
      delete or purge brings the todo back. Decide in 3b: hide ids whose latest
      event is `.deleted`, or accept and document it.
- [ ] **Unverified:** whether mirroring merges per field or per record. Nothing
      may rely on per-field merging.

#### Phase 3b (done): sync on, made safe

**Entitlements.** The app has `icloud-container-identifiers`
(`iCloud.lueddemann.howy`), `icloud-services` (CloudKit),
`ubiquity-kvstore-identifier` (`$(TeamIdentifierPrefix)lueddemann.howy`) and
`com.apple.developer.aps-environment` (the macOS key) = `development`. Debug
signs with `Howy/Howy.entitlements`, Release with `Howy/Howy-Release.entitlements`,
which adds `icloud-container-environment = Production` (`CODE_SIGN_ENTITLEMENTS`
per configuration in `project.yml`; both files are edited by hand). The widget
has only the sandbox and the App Group. `aps-environment` is `development` in
Release too: every build is signed "Apple Development" with a development
profile, which only allows that value. Verified with
`codesign -d --entitlements -` on both builds.

**Store per configuration.** `HOWY_STORE_FILE_NAME` (`Howy-Debug.store` in
Debug, `Howy.store` in Release) reaches both targets' Info.plist as
`HowyStoreFileName`; `TodoStore.storeFileName` reads it (anything odd or missing
means `Howy.store`). So Debug (Development) and Release (Production) never share
a file, and the widget opens its own app's file. The backups and the
attachments are scoped the same way (`TodoStore.storeScopedName`): Release keeps
`Backups/` and `Attachments/`, Debug uses `Backups-Howy-Debug/` and
`Attachments-Howy-Debug/`. Shared folders would let a Debug run take the day's
backup slot (so the real store isn't backed up that day), prune real backups, or
trash real attachment folders as orphans (the orphan brakes don't stop that with
three folders or fewer). The Debug store and its folders start empty; earlier
Debug builds used the real `Howy.store`.

**Fallback.** `SharedContainer` builds `.local` on the same file when the
`.iCloud` build throws, keeps the reason (`TodoStore.sharedSyncFallbackReason`)
and never tries CloudKit again in that process. `SyncState.Mode.unavailable`
carries it for the status line.

**Date quantization.** Before a store first mirrors, `makeContainer` opens it
with `.none` (running the migration), rounds every `Todo` and `TodoEvent` date
to whole milliseconds (`DateQuantization`), saves, drops that container and only
then builds the mirroring one. So the first export already sees whole
milliseconds. The flag is `howy.datesQuantized.<file name>` in the App Group
defaults. If it throws, the CloudKit build counts as failed: the run falls back
to local and the next launch tries again.

**Sync events.** `SyncMonitor` (HowyCore) observes
`NSPersistentCloudKitContainer.eventChangedNotification` from `HowyApp.init`
(before the container exists). The event is read on the posting queue into a
`SyncEvent` (kind, start, end, succeeded, error domain/code/description) and
only that crosses to the main actor. SwiftData's CloudKit store runs on Core
Data's mirroring, which posts this notification; the internal container isn't
exposed, so the observation can't be filtered to our store, but there's only one
mirroring store per process. **Not yet seen in a running build** (hand test
below). `SyncState` tracks in-flight events, phase, last import/export, last
error (cleared by the next successful import or export), first import done, a
failed setup, and the fallback reason.

**SyncGate.** The cleanups (duplicates, deleted todos that came back, orphaned
attachments), the daily backup and the archive purge run only when the store
doesn't mirror, or when the first import since launch succeeded (or the last
setup failed, e.g. no account, so nothing will arrive), nothing is in flight and
no event came for 30 s. The purge also waits for the retention to be known.
A closed gate defers the work (`AppController.deferredMaintenance`,
`deferredPurge`); it is retried on every sync event, on a key-value store change
and at the date the gate names. A gate that closes between maintenance steps
defers the rest. After each successful import the app reloads the widgets,
rebuilds the due notifications, refreshes an open Browse or Archive panel (an
open edit or create screen is left alone) and schedules a gated maintenance run
and purge.

Consequence: an offline launch (no import succeeds) runs no backup and no
cleanup until the network is back. Accepted; the backup is the safety net for a
wipe, which needs the network too.

**Widget writes while the app runs.** The widget's `.none` store posts
`StoreChangeSignal.name` as before (notifications) and, being an app extension,
also `StoreChangeSignal.extensionName`; the app refreshes an open Browse or
Archive panel on it. Whether the mirroring then exports the widget's write right
away or only at the next launch or import is a hand test.

**Archive retention.** `ArchiveRetentionStore` (HowyCore) over a
`KeyValueStoring` protocol (`UserDefaults`, `NSUbiquitousKeyValueStore`). The
app calls `synchronize()` at launch (`false` → KVS unavailable, local value
only) and observes `didChangeExternallyNotification`. KVS's value wins and is
cached in `UserDefaults`. If KVS has none, the value isn't *known* until KVS
reports a change or 60 s pass; then the local value counts and, if it was set on
this Mac, seeds KVS. A fresh Mac never seeds the default. The purge waits until
the value is known. Risk: a Mac with its own older choice whose KVS download
takes longer than 60 s seeds its value over the other Mac's.

**Deleted todos coming back.** Rule, applied by every device in the gated
cleanup (`TodoStore.removeDeletedTodos`): a todo row whose `updatedAt` is at or
before the newest `deleted` event of its id (in milliseconds) is deleted. Only
synced values decide. An edit made after the delete on another Mac (newer
`updatedAt`) keeps the todo: edit wins over delete. Re-importing a backup that
contains a deleted todo keeps it, since the importer stamps `updatedAt` with the
clock's now. Importing a file whose *events* say a todo was deleted, into a store
where that todo is unchanged since, removes it at the next cleanup (it follows
the history, as sync would). A purged todo has no `deleted` event; if a late
twin brings it back, the next gated purge removes it again. Reads don't hide such
rows; they show until the cleanup runs (after the quiet period).

**Hand tests added by 3b:**

- Launch the Debug build once and check Console (subsystem `lueddemann.howy`):
  the store opens with CloudKit (no "CloudKit store unavailable"), the
  quantization log line, and that sync events arrive (setup, import, export).
- With nothing in iCloud yet, the gate opens once the first import ends and
  30 s pass; the backup and cleanups then run (log lines).
- Not signed in to iCloud: the setup fails and the gate opens after 30 s.
- Retention: change it on one Mac, the other follows (Settings, archive panel).
- Widget tick while Howy runs: an open Browse panel updates; the other Mac gets
  it (now or after the next launch).

**Left for Phase 3c:** account status (`CKContainer.accountStatus`,
`CKAccountChanged`, identity token, `userDeletedZone` as a wipe), the Settings
status line (from `AppController.syncMonitor.state`), error notifications and the
CKError matrix, the CloudKit Console steps and the Production schema deploy, the
2.0.0 CHANGELOG and README, and the two-Mac hand tests.

### PR 3: attachment sync

Later, before the iOS app. Its design is decided then: a `CKAsset` per file
versus `@Attribute(.externalStorage)` data in the model.

### Later

- Stats screen, built on `TodoEvent` (e.g. days from creation to done, how
  often due dates are pushed back, quadrant moves).
- iOS app on top of `HowyCore`.
