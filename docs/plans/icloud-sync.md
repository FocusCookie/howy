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

- [ ] Schema v3 (`HowySchemaV2` frozen, `.unique` dropped, defaults,
      `updatedAt`) and migration plan. Tests: v1 and v2 stores open under v3
      with data intact.
- [ ] `TodoEvent` model, with `TodoStore` writing events for every listed kind
      in the same save. Tests per kind.
- [ ] Event backfill during migration. Test.
- [ ] Duplicate cleanup. Test.
- [ ] Orphaned-attachment cleanup. Test.
- [ ] Export/import includes events, with a new format version that still reads
      old files. Tests.
- [ ] Daily automatic export, keeping the last 7. Test with `FakeClock`.
- [ ] README, CHANGELOG and flow doc comments.

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

### PR 3: attachment sync

Later, before the iOS app. Its design is decided then: a `CKAsset` per file
versus `@Attribute(.externalStorage)` data in the model.

### Later

- Stats screen, built on `TodoEvent` (e.g. days from creation to done, how
  often due dates are pushed back, quadrant moves).
- iOS app on top of `HowyCore`.
