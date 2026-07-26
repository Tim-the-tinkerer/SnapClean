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

- macOS 13 or later
- An administrator account (to authorize deletes)
- Xcode Command Line Tools / Swift toolchain (to build)

## Build & run

```bash
cd ~/SnapClean
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
- The app never stores your password. Elevation uses macOS Authorization Services for this process only.
- System policy may still expire rights after a long idle period; the next delete will prompt again.
- Only validated `YYYY-MM-DD-HHMMSS` date tokens from `tmutil` are ever passed to the delete command.

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
    └── SnapshotService.swift  # List / delete via tmutil
```
