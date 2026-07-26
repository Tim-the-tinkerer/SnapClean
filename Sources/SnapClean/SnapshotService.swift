import Darwin
import Foundation

/// Local Time Machine snapshots on APFS volumes, listed and deleted via `tmutil`.
///
/// Deletion requires administrator privileges (same as `sudo tmutil deletelocalsnapshots …`).
/// Listing does not require elevation.
enum SnapshotService {
    static let tmutilPath = "/usr/bin/tmutil"

    /// Snapshot date format used by `tmutil` (e.g. `2026-07-24-165336`).
    private static let dateRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#
    )

    private static let fullNameRegex = try! NSRegularExpression(
        pattern: #"^com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})\.local$"#
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
            let named = namedSnapshotsByToken()
            let snapshots = tokens.map { token -> LocalSnapshot in
                let full = named[token] ?? "com.apple.TimeMachine.\(token).local"
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

    /// Deletes the given snapshot date tokens. Validates every token, then runs one
    /// elevated shell script so the user authenticates only once.
    ///
    /// Does **not** measure free space (call ``freeBytes()`` / ``freeBytesAfterDelete`` separately
    /// so sampling can run off the main thread).
    ///
    /// **Threading:** Call only from the main thread (`NSAppleScript` is not thread-safe).
    static func deleteSnapshots(dateTokens: [String]) -> OpResult {
        let validated = validatedTokens(dateTokens)
        if let message = validated.error {
            return .failed(message)
        }
        guard let unique = validated.tokens else {
            return .failed("No snapshots selected.")
        }

        // Build a shell loop with only validated YYYY-MM-DD-HHMMSS tokens (no user input).
        // Uses session AuthorizationRef so the password dialog appears once per app launch
        // (rights may still expire per system policy).
        let quoted = unique.map { "'\($0)'" }.joined(separator: " ")
        let shell = "for d in \(quoted); do \(tmutilPath) deletelocalsnapshots \"$d\" || exit 1; done"
        switch PrivilegedSession.shared.runShell(shell) {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        case .success:
            // Caller fills freeBefore/freeAfter when measuring reclaim.
            return .success(DeleteOutcome(
                deletedCount: unique.count,
                freeBefore: nil,
                freeAfter: nil
            ))
        }
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

    private static func parseDateTokens(from output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidDateToken($0) }
    }

    /// Best-effort map of date token → full snapshot name from common mount points.
    private static func namedSnapshotsByToken() -> [String: String] {
        var map: [String: String] = [:]
        let mounts = ["/", "/System/Volumes/Data"]
        for mount in mounts {
            guard case .success(let output) = runUnprivileged(
                executable: tmutilPath,
                arguments: ["listlocalsnapshots", mount]
            ) else { continue }

            for line in output.components(separatedBy: .newlines) {
                let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(name.startIndex..., in: name)
                if let match = fullNameRegex.firstMatch(in: name, options: [], range: range),
                   let tokenRange = Range(match.range(at: 1), in: name) {
                    map[String(name[tokenRange])] = name
                }
            }
        }
        return map
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

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure("Failed to run \(executable): \(error.localizedDescription)")
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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
