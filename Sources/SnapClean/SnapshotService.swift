import Darwin
import Foundation

/// Local Time Machine snapshots on APFS volumes.
///
/// Listing uses `tmutil`. Deletion uses `tmutil deletelocalsnapshots`, which
/// asks backupd to unmount a protected browse and then remove the snapshot.
/// `diskutil` cannot do that unmount: a browse can stay “mounted” after its
/// path is already gone, and delete then fails with -69528.
///
/// The date form also walks other mounted disks and often exits non-zero with
/// “Device not configured” on those browse mounts. SnapClean treats the delete
/// as successful when the snapshot is gone from the APFS volume that stored it.
///
/// Backup stores are left alone. That includes `tmutil destinationinfo` mounts,
/// `/Volumes/.timemachine`, and names ending in `.backup`.
///
/// Deletion requires administrator privileges. Listing does not.
enum SnapshotService {
    static let tmutilPath = "/usr/bin/tmutil"
    static let diskutilPath = "/usr/sbin/diskutil"

    /// Snapshot date format used by `tmutil` (e.g. `2026-07-24-165336`).
    private static let dateRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#
    )

    private static let fullNameRegex = try! NSRegularExpression(
        pattern: #"^com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})\.local$"#
    )

    /// `disk3s5`, `disk3s1s1`, `disk10s2`.
    private static let diskIDRegex = try! NSRegularExpression(
        pattern: #"^disk\d+(s\d+)+$"#
    )

    // MARK: - Models

    struct LocalSnapshot: Identifiable, Hashable, Sendable {
        /// `tmutil` date token used for deletion (`YYYY-MM-DD-HHMMSS`).
        var id: String { dateToken }

        let dateToken: String
        let fullName: String
        let created: Date?
        let volumeLabel: String

        var displayName: String {
            guard let created else { return dateToken }
            return Self.displayFormatter.string(from: created)
        }

        var relativeAge: String {
            guard let created else { return "" }
            return Self.relativeFormatter.localizedString(for: created, relativeTo: Date())
        }

        private static let displayFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return f
        }()
    }

    struct VolumeSummary: Sendable {
        let freeBytes: Int64?
        let totalBytes: Int64?
        let volumeName: String
    }

    /// Result of a delete, including measured free-space change on the data volume.
    struct DeleteOutcome: Equatable, Sendable {
        let deletedCount: Int
        /// Free bytes immediately before the delete ran.
        let freeBefore: Int64?
        /// Free bytes after the delete (best of several samples while APFS settles).
        let freeAfter: Int64?

        /// `freeAfter - freeBefore`. Positive means free space grew.
        /// `nil` if either sample was unavailable.
        var reclaimedBytes: Int64? {
            guard let freeBefore, let freeAfter else { return nil }
            return freeAfter - freeBefore
        }

        var successMessage: String {
            let countPart: String
            if deletedCount == 1 {
                countPart = "Deleted 1 snapshot"
            } else {
                countPart = "Deleted \(deletedCount) snapshots"
            }

            guard let reclaimed = reclaimedBytes else {
                return "\(countPart). Could not measure free space change."
            }

            if reclaimed > 0 {
                let size = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
                return "\(countPart) · Freed \(size)"
            }
            if reclaimed == 0 {
                return "\(countPart) · Free space unchanged (blocks still shared with other snapshots or the live volume)"
            }
            // Negative: other processes used space, or accounting noise.
            let size = ByteCountFormatter.string(fromByteCount: abs(reclaimed), countStyle: .file)
            return "\(countPart) · Free space decreased by \(size) (other disk activity likely)"
        }
    }

    enum OpResult: Equatable {
        case success(DeleteOutcome)
        case cancelled
        case failed(String)
    }

    // MARK: - List

    /// Lists local Time Machine snapshot dates across all disks.
    /// On failure, `errorMessage` is non-nil and `snapshots` is empty.
    static func listSnapshots() -> (snapshots: [LocalSnapshot], errorMessage: String?) {
        guard FileManager.default.fileExists(atPath: tmutilPath) else {
            return ([], "Could not find \(tmutilPath). This tool requires macOS.")
        }

        let datesResult = runUnprivileged(
            executable: tmutilPath,
            arguments: ["listlocalsnapshotdates"]
        )
        switch datesResult {
        case .failure(let message):
            return ([], message)
        case .success(let output):
            let tokens = parseDateTokens(from: output)
            // Names are the date token plus the fixed Time Machine suffix.
            // `tmutil listlocalsnapshots` walks browse mounts and can hang when
            // one of those folders is already gone, so the list does not call it.
            let snapshots = tokens.map { token -> LocalSnapshot in
                let full = snapshotName(for: token)
                return LocalSnapshot(
                    dateToken: token,
                    fullName: full,
                    created: parseDate(token),
                    volumeLabel: "Local"
                )
            }
            // Newest first
            let sorted = snapshots.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            return (sorted, nil)
        }
    }

    private static let dataVolumePath = "/System/Volumes/Data"

    /// Free / total space for the system data volume (best-effort).
    static func volumeSummary() -> VolumeSummary {
        let url = URL(fileURLWithPath: dataVolumePath)
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
            .volumeNameKey,
        ])
        let free = freeBytes()
        let total = values?.volumeTotalCapacity.map { Int64($0) }
        let name = values?.volumeName ?? "Macintosh HD — Data"
        return VolumeSummary(freeBytes: free, totalBytes: total, volumeName: name)
    }

    /// Current free bytes on the data volume (Finder-style “important usage” first).
    static func freeBytes() -> Int64? {
        let url = URL(fileURLWithPath: dataVolumePath)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            return Int64(truncatingIfNeeded: free)
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity {
            return Int64(free)
        }
        // statfs fallback
        var stats = statfs()
        if statfs(dataVolumePath, &stats) == 0 {
            return Int64(stats.f_bavail) * Int64(stats.f_bsize)
        }
        return nil
    }

    /// Samples free space several times after a delete so APFS can settle.
    /// Returns the highest free value observed (most reclaim).
    static func freeBytesAfterDelete(baseline: Int64?, samples: Int = 6, intervalNanoseconds: UInt64 = 250_000_000) -> Int64? {
        var best = freeBytes()
        for _ in 0..<samples {
            // Busy-wait friendly for main-thread AppleScript follow-up; short intervals only.
            Thread.sleep(forTimeInterval: Double(intervalNanoseconds) / 1_000_000_000)
            guard let current = freeBytes() else { continue }
            if best == nil || current > (best ?? 0) {
                best = current
            }
            // Early exit once free space has clearly increased past baseline.
            if let baseline, current > baseline {
                // Still take one more sample for a slightly better max, then stop next loop.
                Thread.sleep(forTimeInterval: Double(intervalNanoseconds) / 1_000_000_000)
                if let again = freeBytes(), again > (best ?? 0) {
                    best = again
                }
                break
            }
        }
        return best
    }

    // MARK: - Delete

    /// Validates tokens and returns the unique sorted list, or an error message.
    static func validatedTokens(_ dateTokens: [String]) -> (tokens: [String]?, error: String?) {
        let unique = Array(Set(dateTokens)).sorted()
        guard !unique.isEmpty else {
            return (nil, "No snapshots selected.")
        }
        for token in unique {
            guard isValidDateToken(token) else {
                return (nil, "Invalid snapshot date: \(token)")
            }
        }
        guard FileManager.default.fileExists(atPath: tmutilPath) else {
            return (nil, "Could not find \(tmutilPath).")
        }
        return (unique, nil)
    }

    /// Session authorization is available on this Mac.
    /// When false, each delete uses an administrator `osascript` prompt instead.
    static var prefersSessionAuthorization: Bool {
        PrivilegedSession.shared.canExecuteWithPrivileges
    }

    /// Runs an already-built delete script. Does **not** measure free space.
    ///
    /// Pass `authorize: false` only after ``PrivilegedSession/ensureAuthorized()``
    /// has succeeded on the main thread. The script itself may run in the background.
    static func runDeletion(script: String, deletedCount: Int, authorize: Bool) -> OpResult {
        switch PrivilegedSession.shared.runShell(script, authorize: authorize) {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        case .success:
            return .success(DeleteOutcome(
                deletedCount: deletedCount,
                freeBefore: nil,
                freeAfter: nil
            ))
        }
    }

    /// One elevated `tmutil deletelocalsnapshots` per date, then a check that the
    /// name is gone from each APFS disk that had it. The script is nil when `error` is set.
    static func deletionPlan(dateTokens: [String]) -> (script: String?, deletedCount: Int?, error: String?) {
        let validated = validatedTokens(dateTokens)
        if let message = validated.error {
            return (nil, nil, message)
        }
        guard let unique = validated.tokens else {
            return (nil, nil, "No snapshots selected.")
        }
        guard FileManager.default.isExecutableFile(atPath: diskutilPath)
            || FileManager.default.fileExists(atPath: diskutilPath)
        else {
            return (nil, nil, "Could not find \(diskutilPath).")
        }

        let namesByDisk = snapshotNamesByDisk()
        // tmutil's exit status is not the result. Browse mounts make it non-zero
        // after backupd has already removed the snapshot from the real volume.
        // `_sc_run` bounds each tool so a hung tmutil cannot sit forever.
        var lines = ["set +e", shellRunner]
        var planned = 0
        var missing: [String] = []

        for token in unique {
            let name = snapshotName(for: token)
            let disks = namesByDisk.keys.sorted().filter { namesByDisk[$0]?.contains(name) == true }
            if disks.isEmpty {
                missing.append(token)
                continue
            }
            guard isValidSnapshotName(name) else {
                return (nil, nil, "Refusing to delete an unexpected snapshot name.")
            }
            lines.append("_tm_out=$( _sc_run 20 \(tmutilPath) deletelocalsnapshots '\(token)' )")
            lines.append("_tm_status=$?")
            for disk in disks {
                guard isValidDiskID(disk) else {
                    return (nil, nil, "Refusing to delete an unexpected disk or snapshot name.")
                }
                lines.append(contentsOf: confirmationLines(disk: disk, name: name))
            }
            planned += 1
        }

        if !missing.isEmpty {
            return (nil, nil, "Could not find \(missing.joined(separator: ", ")) on a local APFS volume.")
        }
        guard planned > 0 else {
            return (nil, nil, "No snapshots selected.")
        }
        return (lines.joined(separator: "\n"), unique.count, nil)
    }

    /// Poll `diskutil apfs listSnapshots` until `name` is gone, or report failure.
    /// Disk id and snapshot name are already validated and contain no shell metacharacters.
    private static func confirmationLines(disk: String, name: String) -> [String] {
        [
            "_gone=0",
            "_i=0",
            "while [ \"$_i\" -lt 8 ]; do",
            "  _snap_list=$( _sc_run 15 \(diskutilPath) apfs listSnapshots \(disk) )",
            "  _snap_status=$?",
            "  if [ \"$_snap_status\" -ne 0 ]; then",
            "    printf '%s\\n' \"$_snap_list\"",
            "    exit 1",
            "  fi",
            "  if ! printf '%s\\n' \"$_snap_list\" | grep -F -q '\(name)'; then",
            "    _gone=1",
            "    break",
            "  fi",
            "  _i=$((_i + 1))",
            "  sleep 0.4",
            "done",
            "if [ \"$_gone\" -ne 1 ]; then",
            "  printf '%s\\n' \"$_tm_out\" | tail -n 12",
            "  echo \"Snapshot \(name) is still present on \(disk).\"",
            "  exit 1",
            "fi",
        ]
    }

    /// `sh -n` on the privileged script. Does not run it.
    private static func shellSyntaxError(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        if process.terminationStatus == 0 { return nil }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "status \(process.terminationStatus)" : trimmed
    }

    /// Lists snapshots and the delete command for each. Does not delete.
    static func runSelfTest() -> Int32 {
        func emit(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        let listed = listSnapshots()
        if let message = listed.errorMessage {
            emit("list failed: \(message)")
            return 1
        }

        emit("listed \(listed.snapshots.count) snapshot(s)")
        if listed.snapshots.isEmpty {
            if let runnerError = shellRunnerProbeError() {
                emit("shell runner: \(runnerError)")
                return 1
            }
            emit("ok")
            return 0
        }

        let tokens = listed.snapshots.map(\.dateToken)
        let plan = deletionPlan(dateTokens: tokens)
        if let message = plan.error {
            emit("plan failed: \(message)")
            return 1
        }
        guard let script = plan.script else {
            emit("plan failed: empty script")
            return 1
        }

        for line in script.components(separatedBy: .newlines) where line.contains("deletelocalsnapshots") || line.contains("still present") {
            emit(line)
        }
        if let syntaxError = shellSyntaxError(script + "\necho SNAPCLEAN_OK\n") {
            emit("shell syntax: \(syntaxError)")
            return 1
        }
        for token in tokens {
            let name = snapshotName(for: token)
            guard script.contains("deletelocalsnapshots '\(token)'") else {
                emit("plan missing delete for \(token)")
                return 1
            }
            guard script.contains("Snapshot \(name) is still present on ") else {
                emit("plan missing confirmation for \(name)")
                return 1
            }
        }
        guard !script.contains("deleteSnapshot") else {
            emit("plan still calls diskutil deleteSnapshot")
            return 1
        }
        guard script.contains("_sc_run 20 "), script.contains("_sc_run 15 ") else {
            emit("plan missing command timeout")
            return 1
        }
        for mount in backupMountPoints() {
            if let disk = deviceIdentifier(mount: mount), script.contains("listSnapshots \(disk)") {
                emit("plan scans backup disk \(disk) (\(mount))")
                return 1
            }
        }
        if let runnerError = shellRunnerProbeError() {
            emit("shell runner: \(runnerError)")
            return 1
        }
        if let syntaxError = appleScriptSyntaxError(script + "\necho SNAPCLEAN_OK\n") {
            emit("osascript syntax: \(syntaxError)")
            return 1
        }
        emit("ok")
        return 0
    }

    /// Bounded runner embedded in the elevated script. `/bin/sh` is bash 3.2,
    /// which has no `timeout` and treats an exited child as still alive for `kill -0`
    /// until it is reaped, so a watcher sleeps beside a blocking `wait`.
    private static let shellRunner = """
    _sc_run() {
      _secs="$1"
      shift
      _tmp=$(mktemp "${TMPDIR:-/tmp}/snapclean.XXXXXX") || return 99
      "$@" >"$_tmp" 2>&1 &
      _pid=$!
      (
        _left="$_secs"
        while [ "$_left" -gt 0 ]; do
          sleep 1
          _left=$((_left - 1))
          kill -0 "$_pid" 2>/dev/null || exit 0
        done
        kill "$_pid" 2>/dev/null
        sleep 0.2
        kill -9 "$_pid" 2>/dev/null
      ) &
      _watch=$!
      wait "$_pid"
      _st=$?
      kill "$_watch" 2>/dev/null
      wait "$_watch" 2>/dev/null
      cat "$_tmp"
      rm -f "$_tmp"
      if [ "$_st" -eq 143 ] || [ "$_st" -eq 137 ]; then
        echo "timed out after ${_secs}s"
        return 124
      fi
      return "$_st"
    }
    """

    private static func shellRunnerProbeError() -> String? {
        let probe = """
        set +e
        \(shellRunner)
        _out=$(_sc_run 3 /bin/echo snapclean-probe)
        _st=$?
        if [ "$_st" -ne 0 ] || [ "$_out" != "snapclean-probe" ]; then
          echo "probe status $_st output $_out"
          exit 1
        fi
        _out=$(_sc_run 1 /bin/sleep 4)
        _st=$?
        if [ "$_st" -ne 124 ]; then
          echo "timeout status $_st output $_out"
          exit 1
        fi
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", probe]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        if process.terminationStatus == 0 { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = (text + errText).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "status \(process.terminationStatus)" : trimmed
    }

    /// Compiles the administrator fallback without running it.
    private static func appleScriptSyntaxError(_ script: String) -> String? {
        let source = PrivilegedSession.shared.appleScriptSource(for: script)
        let directory = FileManager.default.temporaryDirectory
        let src = directory.appendingPathComponent("snapclean-osascript-test.applescript")
        let out = directory.appendingPathComponent("snapclean-osascript-test.scpt")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: out)
        }
        do {
            try source.write(to: src, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", out.path, src.path]
        process.standardInput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        if process.terminationStatus == 0 { return nil }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "status \(process.terminationStatus)" : trimmed
    }

    /// `com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.local` for a validated date token.
    static func snapshotName(for dateToken: String) -> String {
        "com.apple.TimeMachine.\(dateToken).local"
    }

    /// Builds a full outcome after elevated delete + free-space sampling.
    static func makeOutcome(deletedCount: Int, freeBefore: Int64?, freeAfter: Int64?) -> DeleteOutcome {
        DeleteOutcome(deletedCount: deletedCount, freeBefore: freeBefore, freeAfter: freeAfter)
    }

    /// Whether this process already has session admin rights (no password stored).
    static var hasSessionAuthorization: Bool {
        PrivilegedSession.shared.isAuthorized
    }

    /// Forget session authorization; next delete will prompt again.
    static func forgetSessionAuthorization() {
        PrivilegedSession.shared.invalidate()
    }

    // MARK: - Parsing helpers

    private static func isValidDateToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return dateRegex.firstMatch(in: token, options: [], range: range) != nil
    }

    private static func isValidDiskID(_ disk: String) -> Bool {
        let range = NSRange(disk.startIndex..., in: disk)
        return diskIDRegex.firstMatch(in: disk, options: [], range: range) != nil
    }

    private static func isValidSnapshotName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return fullNameRegex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Mounts worth scanning. Time Machine browse mounts under
    /// `/Volumes/com.apple.TimeMachine.localsnapshots` are skipped: deleting
    /// through them returns ENXIO (“Device not configured”).
    private static func candidateMounts() -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        let backups = backupMountPoints()

        func add(_ path: String) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return }
            guard !isExcludedMount(standardized) else { return }
            guard !backups.contains(standardized) else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else { return }
            guard isAPFS(standardized) else { return }
            result.append(standardized)
        }

        add(dataVolumePath)
        add("/")
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        for url in urls {
            add(url.path)
        }
        return result
    }

    /// Mounts that must never be scanned for a delete.
    /// Local snapshots live on the data volume. Backup stores, the sealed
    /// system volumes, and Time Machine browse mounts do not.
    private static func isExcludedMount(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower == dataVolumePath.lowercased() { return false }
        if lower.contains("/.timemachine") || lower.hasSuffix("/.timemachine") { return true }
        if lower.contains("com.apple.timemachine.localsnapshots") { return true }
        if lower.contains("/backups.backupdb") { return true }
        if lower.hasPrefix("/system/volumes/") { return true }
        if lower == "/volumes/recovery" { return true }
        return false
    }

    /// Mount points reported by `tmutil destinationinfo`.
    private static func backupMountPoints() -> Set<String> {
        guard case .success(let output) = runUnprivileged(
            executable: tmutilPath,
            arguments: ["destinationinfo"]
        ) else { return [] }

        var mounts = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "mount point" else { continue }
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            mounts.insert(URL(fileURLWithPath: value).standardizedFileURL.path)
        }
        return mounts
    }

    private static func isAPFS(_ path: String) -> Bool {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return false }
        let type = withUnsafeBytes(of: stats.f_fstypename) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return type == "apfs"
    }

    private static func deviceIdentifier(mount: String) -> String? {
        guard case .success(let output) = runUnprivileged(
            executable: diskutilPath,
            arguments: ["info", "-plist", mount]
        ) else { return nil }
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let id = plist["DeviceIdentifier"] as? String,
              isValidDiskID(id)
        else { return nil }
        return id
    }

    /// Snapshot names present on each real APFS disk, keyed by device identifier.
    private static func snapshotNamesByDisk() -> [String: Set<String>] {
        var namesByDisk: [String: Set<String>] = [:]
        for mount in candidateMounts() {
            guard let disk = deviceIdentifier(mount: mount) else { continue }
            if namesByDisk[disk] != nil { continue }
            namesByDisk[disk] = snapshotNames(on: disk)
        }
        return namesByDisk
    }

    private static func snapshotNames(on disk: String) -> Set<String> {
        guard isValidDiskID(disk) else { return [] }
        guard case .success(let output) = runUnprivileged(
            executable: diskutilPath,
            arguments: ["apfs", "listSnapshots", disk]
        ) else { return [] }

        var names = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "com.apple.TimeMachine.") else { continue }
            let name = String(trimmed[range.lowerBound...])
            if isValidSnapshotName(name) {
                names.insert(name)
            }
        }
        return names
    }

    private static func parseDateTokens(from output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidDateToken($0) }
    }

    private static func parseDate(_ token: String) -> Date? {
        // token: 2026-07-24-165336
        guard token.count == 17 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: token)
    }

    // MARK: - Process / AppleScript

    private enum CommandResult {
        case success(String)
        case failure(String)
    }

    private static func runUnprivileged(
        executable: String,
        arguments: [String]
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }

        // Read while the tool runs. Waiting first deadlocks once a pipe fills.
        let stdoutBox = CollectedOutput()
        let stderrBox = CollectedOutput()
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = out.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = err.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }

        do {
            try process.run()
        } catch {
            finished.leave()
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = io.wait(timeout: .now() + 2)
            return .failure("Failed to run \(executable): \(error.localizedDescription)")
        }

        if finished.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            _ = io.wait(timeout: .now() + 2)
            return .failure("\(URL(fileURLWithPath: executable).lastPathComponent) timed out.")
        }

        _ = io.wait(timeout: .now() + 2)
        let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                return .failure(message)
            }
            return .failure("\(executable) exited with status \(process.terminationStatus).")
        }
        return .success(stdout)
    }

}

/// Bytes collected from one pipe. Written on a single queue, read after that queue finishes.
private final class CollectedOutput: @unchecked Sendable {
    var data = Data()
}
