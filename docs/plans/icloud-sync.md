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

- [ ] iCloud capability with CloudKit and container `iCloud.lueddemann.howy`,
      in `project.yml`, for both app and widget.
- [ ] Debug uses Development; Release uses Production through the entitlement.
- [ ] `TodoStore` with `cloudKitDatabase: .private(…)`.
- [ ] Remote-change handling: widgets, UI, notifications, cleanups.
- [ ] Archive retention through `NSUbiquitousKeyValueStore`.
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
  - [ ] Don't run the duplicate cleanup while a remote import is still in flight.
        (Phase 3b, needs the CloudKit event notifications.)
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

#### Notes for Phase 3b

- Dates are compared at whole milliseconds in the duplicate rules, on the
  assumption that a CloudKit round trip keeps milliseconds. Check by hand that
  a row synced to the other Mac compares identical to its original, e.g. the
  backfilled events, which get the same derived ids on every Mac: after a sync
  the cleanup must report nothing removed.

### PR 3: attachment sync

Later, before the iOS app. Its design is decided then: a `CKAsset` per file
versus `@Attribute(.externalStorage)` data in the model.

### Later

- Stats screen, built on `TodoEvent` (e.g. days from creation to done, how
  often due dates are pushed back, quadrant moves).
- iOS app on top of `HowyCore`.
