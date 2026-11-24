# Changelog

## 1.2.5 — 2026-11-23

- Built and stamped for the macOS 27.2 SDK. Window activation uses `NSApp.activate()` on macOS 14 and later
- The app opts in to secure restorable state in Info.plist as well as the delegate
- Deletes run off the main thread after the password dialog, so the window stays responsive
- Each elevated `tmutil` and `diskutil` call times out instead of hanging the session
- If `AuthorizationExecuteWithPrivileges` is ever removed, delete falls back to one administrator `osascript` prompt
- Time Machine backup disks, `/Volumes/.timemachine`, and other system volumes are not scanned or deleted
- Unprivileged tool output is read while the tool runs, so a long listing cannot stall into a false timeout
- SnapClean → Forget Session Authorization updates the window immediately
- View → Refresh Snapshots is ⌘R

## 1.2.4 — 2026-10-25

- The snapshot list uses `tmutil listlocalsnapshotdates` only. `listlocalsnapshots` walks browse mounts and can sit forever when one of those folders is already gone
- `tmutil` and `diskutil` calls time out after 15 seconds instead of leaving the window on “Loading snapshots…”

## 1.2.3 — 2026-10-25

- Delete through `tmutil deletelocalsnapshots` again so backupd can drop a protected browse mount
- `diskutil unmount` cannot clear that mount once its path is gone, and `deleteSnapshot` then stops with -69528
- A delete counts as success when the snapshot is gone from the APFS volume that stored it

## 1.2.2 — 2026-10-25

- Unmount a snapshot’s Time Machine browse mount before `diskutil apfs deleteSnapshot`
- That mount was leaving the snapshot busy (diskutil error -69528)

## 1.2.1 — 2026-10-25

- Delete a snapshot with `diskutil apfs deleteSnapshot` on the APFS volume that holds it
- Stop using `tmutil deletelocalsnapshots <date>`, which walks every mounted disk and fails on Time Machine browse mounts (“Device not configured”)
- Opt in to secure restorable state
- `--self-test` lists snapshots and the disk each one would be deleted from, without deleting

## 1.2.0 — 2026-07-25

- Session authorization: password dialog once per app launch (password never stored)
- “Forget Auth” control and menu item to clear session rights
- Privileged deletes via Security framework `AuthorizationRef` instead of AppleScript each time

## 1.1.0 — 2026-07-25

- Measure free space before and after each delete
- Report reclaimed space in the success status (e.g. “Deleted 2 snapshots · Freed 1.2 GB”)
- Session total: “Freed this session” in the header
- Explain when free space is unchanged (shared APFS blocks)

## 1.0.0 — 2026-07-25

- Initial release
- List local Time Machine snapshots (`tmutil listlocalsnapshotdates`)
- Multi-select delete and delete-all with confirmation
- Administrator elevation for `tmutil deletelocalsnapshots`
- Volume free-space summary for Macintosh HD — Data
