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
  - ~~CloudKit schema missing (Production not deployed)~~ Moot: there is no
    Production (see "CloudKit environments"); any schema error falls under the
    next point.
  - sync failing continuously for more than an hour

  Being offline or a brief network failure never notifies.

### CloudKit environments

**Decision (supersedes the earlier "Release uses Production" plan):** Debug and
Release builds **both use the Development environment**. There is one
entitlements file (`Howy/Howy.entitlements`) with no
`icloud-container-environment` key. Howy is for personal use, so there is no
Production environment, no schema deploy, and no Deploy Schema step in any
release process.

- **Never press "Reset Development Environment"** in CloudKit Console. The real
  data lives there now; a reset deletes it for good.
- **Debug sees the real data.** Debug (`Howy-Debug.store`) and Release
  (`Howy.store`) are separate files, but both mirror to the same private
  database, so a Debug run downloads, edits and deletes the user's real todos.
  Treat Debug runs against the real account as production. Test destructive
  changes with a second iCloud account or with `.local`.
- **Schema changes** are made in Development by running a build; they are
  additive only in practice (CloudKit can't remove record types or fields that
  exist), so a model change that needs a removal needs a new field name.
- **Verify** the built app's entitlements with
  `codesign -d --entitlements - Howy.app`: `aps-environment` development, the
  container, CloudKit, the key-value store.

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
- [x] Debug and Release both use Development (see "CloudKit environments").
- [x] `TodoStore` with `cloudKitDatabase: .private(…)`.
- [x] Remote-change handling: widgets, UI, notifications, cleanups.
- [x] Archive retention through `NSUbiquitousKeyValueStore`.
- [x] Account status (`CKContainer.accountStatus` and `CKAccountChanged`),
      the Settings status line, and error notifications. (Phase 3c.)
- [x] ~~CloudKit Console steps; schema deployed to Production.~~ Dropped: no
      Production (see "CloudKit environments").
- [ ] Manual tests on two Macs:
  - first upload
  - sign-in after local use
  - sign-out wipe and restore
  - an edit on both Macs at once
  - remote delete with attachments
  - a Release build syncing (Development)
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
- [x] **Account (Phase 3c):** observe `CKAccountChanged` and check `accountStatus`. Detect
      a wipe or account switch with a remembered identity token, and treat
      `userDeletedZone` as a wipe.
- [x] **CKError matrix (Phase 3c):** decide which errors are silent and which notify
      (quota, ~~schema missing in Production~~ (moot, no Production), sync
      failing for over an hour).
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
`com.apple.developer.aps-environment` (the macOS key) = `development`, in
`Howy/Howy.entitlements` for both configurations (no
`icloud-container-environment`, so both use Development; see "CloudKit
environments"). The widget has only the sandbox and the App Group.
`aps-environment` is `development` in Release too: every build is signed "Apple
Development" with a development profile, which only allows that value.
Verified with `codesign -d --entitlements -` on both builds.

**Store per configuration.** `HOWY_STORE_FILE_NAME` (`Howy-Debug.store` in
Debug, `Howy.store` in Release) reaches both targets' Info.plist as
`HowyStoreFileName`; `TodoStore.storeFileName` reads it (anything odd or missing
means `Howy.store`). So Debug and Release never share a file (they do share the iCloud data; see
"CloudKit environments"), and the widget opens its own app's file. A missing or
invalid name makes the app stay `.local` (assertionFailure and a fault log). The backups and the
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

#### Phase 3b fix round (from the reviews)

Made so that a second Mac with an empty or older local store can join without
any maintenance step destroying data before it has imported from iCloud.

- **Archive retention.** With an empty KVS the value is *unknown* for up to 24 h
  (counted from the first launch and remembered, so daily relaunches still
  decide) and nothing is purged. Only a value the user chose on this Mac (not
  one copied from KVS: `isExplicit`) seeds KVS. The change observer is
  registered before `synchronize()`.
- **Self-heal and one-time passes.** `selfHeal` runs only in the app process and
  only on a store file that never mirrored. The mirrored flag
  (`howy.storeMirrored.<file>`) is set when the mirroring container is first
  built; the quantization flag counts as "mirrored" for builds that predate it.
  The heal flag is per file too (the old unscoped key still counts for
  `Howy.store`). A store file that doesn't exist yet skips the preparation.
- **Gate.**
  - Destructive work (duplicates, deleted todos, orphans and trash, archive
    purge) needs an import that *started after* launch or the last wake. The
    wake handler notes the wake and the purge goes through the gate. A new setup
    event resets `firstImportDone`.
  - `setupFailed` only for account/entitlement CKErrors (also when wrapped);
    transient errors never open the gate.
  - An event without an end counts as stale after 10 min.
  - `.waitForSync` retries every 60 s; a gate closed for 30 min logs a fault.
  - The mode is taken from the container that was built (`.starting` until
    then; a CloudKit fallback is `.unavailable`).
- **Backup** has a relaxed gate (sync quiet for 30 s with at least one event, or
  10 min after launch whatever sync does) and runs first (`MaintenancePlan`).
  Every step asks its own gate right before it runs.
- **Import reactions** are debounced by 1 s; the cleanups run at most once per
  10 min (`CleanupThrottle`).
- **Fresh reads.** Duplicate and deleted-todo cleanups and the archive purge
  read on a fresh `ModelContext` right before they delete; the orphan cleanup
  re-reads the todo ids before it trashes a folder.
- **Attachments.** Trashed folders of a todo that exists again are moved back
  (unless it has a new folder); `purgeTrash` skips todos that exist.
- **Off-main setup.** `TodoStore.prepareSharedContainer()` is `@concurrent`; the
  app awaits it at launch. A `shared()` that comes first (a deep link) builds on
  the main actor.
- **Remote notifications.** The app calls
  `NSApplication.shared.registerForRemoteNotifications()` at launch. Apple's
  Core Data + CloudKit article only asks for the iCloud/Push capability, but the
  APNs registration article says a macOS app registers itself, and community
  reports say push-triggered imports otherwise don't arrive on macOS. It costs
  nothing (the `aps-environment` entitlement is there). Check by hand (below).

#### Import nudge and first two-Mac result (2026-10-12)

- **Release crash fixed** (`039ca22`): the duplicate check used a key path that
  crashed release builds after a sync; it now uses the concrete `id` key path.
- **Import nudge** (`2ea64cb`): pushes don't arrive reliably, so a Mac could go
  without importing until its next launch. `AppController.nudgeImport()` posts
  `NSApplication.didBecomeActiveNotification` (Core Data's
  "AppActivationImport" trigger, which Howy's non-activating panels never fire)
  when a panel opens, on wake and every 5 minutes, at most once a minute and
  only in `.iCloud` mode while Howy isn't active.
- **Hand test, two Macs:** changes from one Mac arrive on the other after a
  while, and the Macs stay in sync over time. That covers test 1 (join) and the
  everyday case of test 7 (with the nudge as fallback for pushes). Tests 2–6
  and 8–10 haven't been run yet.

#### Phase 3c (done): account, status line, notifications

All the logic is in HowyCore, tested with Swift Testing (`SyncIncidentsTests`,
`SyncAccountTests`, `SyncStatusTests`); the app only feeds events and posts.

**CKError matrix** (`SyncErrorKind`, `SyncError.kind`). Mirroring wraps the
CloudKit error in a Core Data one and a `partialFailure` carries the real errors
per item (`CKPartialErrorsByItemIDKey`); every code found is classified and the
most serious wins (zone deleted > quota > persistent > account > silent).

| Kind | Codes | Effect |
| --- | --- | --- |
| silent | `networkUnavailable`, `networkFailure`, `serviceUnavailable`, `requestRateLimited`, `zoneBusy`, `accountTemporarilyUnavailable`, `serverResponseLost`, `operationCancelled` | never notifies, never counts; status "Offline" / "Waiting for iCloud" |
| account | `notAuthenticated`, `managedAccountRestricted` | no error notice; the account check handles it |
| quota | `quotaExceeded` | "iCloud storage is full", right away |
| zone deleted | `userDeletedZone` | "Howy's iCloud data was deleted" (a wipe) |
| persistent | everything else, and errors without a CloudKit code | "iCloud sync isn't working" after an hour without a successful import or export |

**Once per incident** (`SyncIncidents`). Storage full: until an export
succeeds. Data removed: until an import or export succeeds; a deleted zone
within 10 min of an account-change notice is the same incident. Failing: the
first persistent error starts the clock, a successful import or export (not a
setup) or losing the account ends it, and it notifies on the event or the
5-minute `tick()` that passes the hour, unless the latest error is silent
(offline right now never notifies). Storage-full and failing notices don't
repeat within 24 h; when each was last posted is kept in `UserDefaults`
(`howy.syncAlertsPosted.<store file>`), so a relaunch doesn't repeat them.

**Account** (`AccountObservation`, `SyncAccountTracker`). `SyncMonitor` keeps a
`CKContainer(identifier: "iCloud.lueddemann.howy")`, reads `accountStatus()` and,
for `.available`, `userRecordID().recordName` at launch, on `CKAccountChanged`
and on wake (only the latest check's answer counts). `.available` with
`userRecordID()` failing `notAuthenticated` counts as "iCloud off for Howy"
(the header: "the device has an iCloud account but the user disables iCloud").
The record name the store last mirrored with is remembered in
`UserDefaults.standard` (`howy.syncAccount.<store file>`, per Mac, per store file,
outside the synced store). Rules: first account seen → remembered quietly
(covers Macs that synced before 3c); another account → "account changed"; no
account / iCloud off / restricted while one is remembered → "sync stopped" and
nothing remembered any more; temporarily unavailable, could not determine, or a
record name that couldn't be fetched → nothing changes. The comparison only
runs while the store mirrors (`.iCloud`): a local fallback run wiped nothing,
and an account read before the container is built is compared at `setMode`.

**Status line** (`SyncStatus`, Settings → iCloud, first section). Mode first
(off / unavailable / checking), then the account (not signed in, iCloud off for
Howy, restricted, waiting), then the last error until a success clears it
(offline, waiting, or "Sync error: <reason>"), then syncing, else "Up to date"
with when it last synced. Re-read every 15 s. Local only and offline aren't
shown as errors.

**Notifications** (`NotificationCoordinator.post(_:)`): delivered at once, one
identifier per kind (`howy.sync.<kind>`, a newer one replaces the older). If
permission was never asked, a sync notice asks. A click opens Settings and
highlights the iCloud line for 2 s (`AppController.showSyncSettings()`).

**Hand tests for 3c** (take a manual export first; Console subsystem
`lueddemann.howy`, "Sync notice:" lines):

1. Mac B: sign out of iCloud while Howy runs → "iCloud sync stopped", the line
   says "Not signed in to iCloud", the todos are gone; sign back in → no notice,
   todos come back, line goes "Syncing…" then "Up to date".
2. Mac B: sign out with Howy quit, relaunch → the notice at launch.
3. Turn iCloud off for Howy only (System Settings → Apple Account → iCloud →
   Saved to iCloud) → check which notice and line you get (unverified: whether
   macOS reports "no account" or "iCloud off for Howy").
4. Turn Wi-Fi off for over an hour → "Offline", no notice.
5. Click a notice → Settings opens with the iCloud line highlighted.
6. A second iCloud account on Mac B (only with a test account) → "iCloud
   account changed".
7. iCloud full and a deleted zone can't be tested easily: quota needs a full
   account, and deleting Howy's data in iCloud settings would delete the real
   data. Leave them to the unit tests.

**Result (2026-10-12):** test 1, sign-out while Howy runs: passed. The sign-out
notice arrived, the Settings line showed sync as off, and the todos were removed
from the Mac as expected. After signing back in, the todos downloaded again and
sync resumed.
Test 2, sign-out with Howy quit: passed. The todos were gone at relaunch and
came back after signing back in.
Test 3, iCloud off for Howy only: passed. A "sync stopped" notice arrived
(macOS reports it like iCloud being off, as guessed). Turning it back on resumed
sync.
Test 5, clicking a notice: passed. Settings opened.
Test 4 (offline for over an hour) is still open. Test 6 is skipped: there's no
second iCloud account.

#### Known limits

- Whether mirroring merges per field or per record is unverified. Nothing may
  rely on per-field merging; a concurrent edit on two Macs can lose one edit.
- **Sign-out wipes the local store** (Apple's behaviour); unsynced changes are
  lost. The daily backup is the safety net; Howy notifies when it sees the
  sign-out or account change (Phase 3c).
- A sign-out and back into the **same** account while Howy wasn't running isn't
  seen (nothing to compare); mirroring downloads everything again, but changes
  that hadn't uploaded are lost without a notice.
- "iCloud off for Howy" is inferred from `userRecordID()` failing
  `notAuthenticated` while the account is available; not checked on a real Mac.
  A one-off `notAuthenticated` there (e.g. right after login) would show a false
  "sync stopped" notice; the remembered account is then dropped, so the next
  good check re-remembers it quietly.
- A first notice on a Mac where notifications were never allowed asks for
  permission then; if they are off, the notice is only logged and the status
  line is the only sign.
- The daily backup taken after a wipe is of the empty store; it only displaces
  the oldest of the 7, and the day's slot is usually taken already.
- **A Mac without any sync event** (offline, no iCloud account) never opens the
  strict gate for an account problem it can't see: the backup still runs after
  10 min, the cleanups and the purge wait. After a wake they wait for an import
  that starts after it, which may take until the next remote change or launch.
- **Debug sees the real data** and can delete it (see "CloudKit environments").
- The widget doesn't receive remote changes: it shows what the app last
  imported. Its checkbox writes through the history, but when the other Mac gets
  it depends on the app's mirroring running.
- Attachments don't sync until PR 3; a todo synced to another Mac has none, and
  the other Mac's orphan cleanup only trashes folders, never deletes at once.
- A delete can still show briefly on another Mac until its gated cleanup runs.
- A backup taken before the first import (the 10 min fail-open) can take the
  day's slot with an older state; the next day's backup has everything.
- `Reset Development Environment` would wipe the real data. Don't.
- Key-value store: a Mac with its own older choice whose KVS download takes
  longer than 24 h seeds its value over the other Mac's.

#### Hand tests: joining a second Mac

Use Console (subsystem `lueddemann.howy`). Take a manual export on the first Mac
first (Export…), and keep `Backups/` safe.

1. **Join with an empty local store.** Install Howy on Mac B signed in to the
   same iCloud account. Check the store opens with CloudKit, the setup and
   import events arrive, and Mac A's todos appear. Nothing is purged (log:
   no "Purged"), no "Removed … duplicate", no "Moved attachments".
2. **Join with an older local store.** Mac B has its own `Howy.store` with a few
   different todos, created before sign-in. After the join both sets are
   present on both Macs; no row vanished; the duplicate cleanup reports nothing
   removed (or only twins it should).
3. **Retention.** On Mac B, Settings shows Mac A's retention (not the default)
   within minutes, and the purge doesn't run before it is known. Change it on B;
   A follows. On a fresh Mac with nothing set, nothing purges for 24 h.
4. **Gate.** With Mac B offline at launch: the backup runs after 10 min, the
   cleanups don't. Go online: after the first import and 30 s the cleanups run
   once; several imports in a row cause one reaction (debounce) and cleanups at
   most every 10 min.
5. **Sleep.** Put Mac B to sleep, change todos on A, wake B: the purge doesn't
   run until an import that started after the wake has finished.
6. **Delete.** Delete a todo on A: it disappears on B after the next import and
   cleanup; its attachment folder on B moves to `.trash` (not deleted), and
   comes back from the trash if the todo is recreated by a twin.
7. **Push.** With both Macs running, add a todo on A: it shows up on B without
   relaunching (confirms `registerForRemoteNotifications()`; if not, B only
   catches up at launch and the 60 s retry loop shows nothing new).
8. **Widget.** Tick a todo in the widget on B with Howy running and not
   running; confirm A gets it (now or after the next launch).
9. **Concurrent edit** of one todo on both Macs: no duplicates, no loss beyond
   one edit.
10. **Debug.** Launch Debug on one Mac: it opens `Howy-Debug.store`, downloads
    the real data, and its backups go to `Backups-Howy-Debug`.

**Phase 3c** is done (see above). The CloudKit Console steps and the
Production schema deploy were dropped (no Production). **Left:** the two-Mac
hand tests (the joining list above and the 3c list), the 2.0.0 release (version
bump, release notes) and the PR.

### PR 3: attachment sync

Later, before the iOS app. Its design is decided then: a `CKAsset` per file
versus `@Attribute(.externalStorage)` data in the model.

### Later

- Stats screen, built on `TodoEvent` (e.g. days from creation to done, how
  often due dates are pushed back, quadrant moves).
- iOS app on top of `HowyCore`.
