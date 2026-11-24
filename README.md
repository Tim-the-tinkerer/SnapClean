# SnapClean

A native macOS app to **browse** and optionally **delete** local Time Machine snapshots.

## What it does

macOS automatically creates **local APFS snapshots** (visible as `com.apple.TimeMachine.…local`) so Time Machine can keep hourly history even when your backup disk is offline. Those snapshots can hold onto disk space until the system purges them.

**SnapClean** lists those snapshots in a simple window and lets you:

- **Refresh** the list (`⌘R`)
- **Select** one or more snapshots and **delete** them (`⌘⌫`)
- **Delete all** local snapshots in one step
- **See reclaimed space** after each delete (measured free space before vs after)

Deletion uses the standard macOS administrator password dialog. **The password is never stored.** After you authenticate once, SnapClean keeps a session `AuthorizationRef` in memory so further deletes in the same app run usually do not re-prompt. Use **Forget Auth** (or **SnapClean → Forget Session Authorization**) to clear that. Quitting the app always discards it.

## Requirements

- macOS 13 or later (tested on macOS 27.2)
- An administrator account (to authorize deletes)
- Xcode Command Line Tools / Swift toolchain (to build)

## Build & run

```bash
cd "/Users/timbestler/Apps - macOS Utility/SnapClean"
chmod +x build-app.sh
./build-app.sh
```

This compiles a release binary, packages `SnapClean.app`, ad-hoc codesigns it, and launches it.

Build without launching:

```bash
./build-app.sh --no-launch
```

Or run the binary directly during development:

```bash
swift run
```

## Usage

1. Open **SnapClean**.
2. Review the list (newest first). Each row shows a human-readable time, the `tmutil` date token, and relative age.
3. Select one or more rows (click, Shift-click, or ⌘-click).
4. Click **Delete N…** or **Delete All…** and confirm.
5. Enter your Mac password when prompted.
6. After a successful delete, the status line shows how much free space increased (e.g. **Freed 420 MB**). The header tracks **Freed this session**.

You can cancel the password dialog; the app reports that as cancelled.

## Notes

- APFS does not expose an exact “size” for each local snapshot ahead of time. SnapClean instead **measures free space** on Macintosh HD — Data before and after delete (with a short settle period).
- Reclaimed space of **0** usually means the deleted snapshot’s blocks were still shared with other snapshots or the live volume.
- Other apps writing to disk during the measurement can affect the free-space delta slightly.
- macOS may create new local snapshots again later; that is normal Time Machine behavior.
- The app never stores your password. Elevation uses macOS Authorization Services for this process only. macOS 27.2 still provides that API. If a later system removes it, SnapClean asks once per delete through the standard administrator dialog.
- Backup disks reported by `tmutil destinationinfo`, hidden Time Machine stores under `/Volumes/.timemachine`, and sealed system volumes are not scanned. Only `.local` snapshots on a data volume are deleted. `com.apple.os.update` snapshots are left alone.
- System policy may still expire rights after a long idle period; the next delete will prompt again.
- Only validated `YYYY-MM-DD-HHMMSS` date tokens are ever passed to the delete command.
- A delete runs `tmutil deletelocalsnapshots` for that date. Time Machine’s backupd is what can unmount a protected browse of the snapshot. `diskutil` reports -69528, “busy (mounted)”, for that same browse, including after the folder itself is already gone.
- That `tmutil` command also visits other mounted disks and often exits with “Device not configured” on Time Machine browse mounts. SnapClean ignores that exit status. The delete succeeded when the snapshot is no longer listed on the APFS volume that stored it.
- `SnapClean --self-test` prints each snapshot and the disk it would be removed from. It does not delete anything.

## Project layout

```
SnapClean/
├── Package.swift
├── AppInfo.plist
├── build-app.sh
├── Scripts/GenerateAppIcon.swift
└── Sources/SnapClean/
    ├── MainEntry.swift        # AppKit entry + window
    ├── ContentView.swift      # SwiftUI UI
    ├── PrivilegedSession.swift # Session admin rights
    └── SnapshotService.swift  # List / delete via tmutil
```
