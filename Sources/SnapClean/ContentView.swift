import SwiftUI

enum BrowseStatus: Equatable {
    case idle
    case loading
    case ready
    case deleting
    case measuring
    case success(String)
    case cancelled
    case failed(String)
}

struct ContentView: View {
    @State private var snapshots: [SnapshotService.LocalSnapshot] = []
    @State private var selection = Set<String>()
    @State private var status: BrowseStatus = .idle
    @State private var volume = SnapshotService.volumeSummary()
    @State private var confirmDeleteSelected = false
    @State private var confirmDeleteAll = false
    /// Cumulative free space reclaimed this app session (only positive deltas).
    @State private var sessionFreedBytes: Int64 = 0
    /// Last successful delete outcome (for detail in the status line).
    @State private var lastOutcome: SnapshotService.DeleteOutcome?
    /// Mirrors PrivilegedSession so the UI refreshes when auth is gained or forgotten.
    @State private var sessionAuthorized = false

    private var isBusy: Bool {
        switch status {
        case .loading, .deleting, .measuring: return true
        default: return false
        }
    }

    private var selectedSnapshots: [SnapshotService.LocalSnapshot] {
        snapshots.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            snapshotList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .snapCleanAuthorizationDidChange)) { _ in
            sessionAuthorized = SnapshotService.hasSessionAuthorization
        }
        .onReceive(NotificationCenter.default.publisher(for: .snapCleanRefreshRequested)) { _ in
            if !isBusy { reload() }
        }
        .alert("Delete selected snapshots?", isPresented: $confirmDeleteSelected) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                performDelete(tokens: selectedSnapshots.map(\.dateToken))
            }
        } message: {
            Text(deleteSelectedMessage)
        }
        .alert("Delete all local snapshots?", isPresented: $confirmDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                performDelete(tokens: snapshots.map(\.dateToken))
            }
        } message: {
            Text(
                "This permanently removes \(snapshots.count) Time Machine local snapshot(s). "
                    + "macOS may recreate them later. After delete, SnapClean measures free space "
                    + "to report how much was reclaimed."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.teal)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text("SnapClean")
                    .font(.headline)
                Spacer(minLength: 0)
                Text(snapshotCountLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            }

            Text("Browse local Time Machine snapshots and optionally delete them to reclaim disk space.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label(volume.volumeName, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let free = volume.freeBytes {
                    Text("Free: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if sessionFreedBytes > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Freed this session: \(ByteCountFormatter.string(fromByteCount: sessionFreedBytes, countStyle: .file))")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.green)
                        .help("Cumulative free space increase measured after deletes in this session")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var snapshotCountLabel: String {
        let n = snapshots.count
        if n == 1 { return "1 snapshot" }
        return "\(n) snapshots"
    }

    // MARK: - List

    private var snapshotList: some View {
        Group {
            if snapshots.isEmpty && !isBusy {
                emptyState
            } else {
                List(snapshots, selection: $selection) { snap in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.teal)
                            .font(.body)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.displayName)
                                .font(.body.weight(.medium))
                            HStack(spacing: 8) {
                                Text(snap.dateToken)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if !snap.relativeAge.isEmpty {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(snap.relativeAge)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(snap.id)
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Delete…", role: .destructive) {
                            selection = [snap.id]
                            confirmDeleteSelected = true
                        }
                        .disabled(isBusy)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .disabled(isBusy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No local snapshots")
                .font(.headline)
            Text("Time Machine has not created any local APFS snapshots right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if sessionFreedBytes > 0 {
                Text("Freed this session: \(ByteCountFormatter.string(fromByteCount: sessionFreedBytes, countStyle: .file))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
                .help("Refresh the snapshot list (⌘R)")

                if sessionAuthorized {
                    Button {
                        SnapshotService.forgetSessionAuthorization()
                        sessionAuthorized = false
                    } label: {
                        Label("Forget Auth", systemImage: "lock.open")
                    }
                    .help("Clear session admin rights. The next delete will ask for your password again.")
                    .disabled(isBusy)
                }

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    confirmDeleteSelected = true
                } label: {
                    Label(deleteSelectedButtonTitle, systemImage: "trash")
                }
                .disabled(isBusy || selectedSnapshots.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)

                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    if isBusy && (status == .deleting || status == .measuring) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(status == .measuring ? "Measuring…" : "Deleting…")
                        }
                    } else {
                        Label("Delete All…", systemImage: "trash.fill")
                    }
                }
                .disabled(isBusy || snapshots.isEmpty)
            }

            statusBanner
                .accessibilityElement(children: .combine)
        }
    }

    private var deleteSelectedButtonTitle: String {
        let n = selectedSnapshots.count
        if n == 0 { return "Delete Selected" }
        if n == 1 { return "Delete 1…" }
        return "Delete \(n)…"
    }

    private var deleteSelectedMessage: String {
        let n = selectedSnapshots.count
        if n == 1, let first = selectedSnapshots.first {
            return "Permanently delete the local snapshot from \(first.displayName)? "
                + "After delete, free space is measured to show how much was reclaimed."
        }
        return "Permanently delete \(n) local snapshots? "
            + "After delete, free space is measured to show how much was reclaimed."
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch status {
        case .idle, .ready:
            if sessionAuthorized {
                Text(selection.isEmpty
                     ? "Authorized for this session (password not stored). Select snapshots to delete."
                     : "\(selection.count) selected · session authorized — further deletes won’t re-prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(selection.isEmpty
                     ? "Select snapshots to delete. First delete asks for your password; later deletes in this session usually won’t."
                     : "\(selection.count) selected. Free space is measured after delete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loading:
            Label("Loading snapshots…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .deleting:
            Label("Deleting snapshots…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .measuring:
            Label("Measuring free space…", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .lineLimit(3)
                .help(message)

        case .cancelled:
            Label("Cancelled.", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(4)
                .help(message)
        }
    }

    // MARK: - Actions

    private func reload() {
        status = .loading
        selection.removeAll()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = SnapshotService.listSnapshots()
            let summary = SnapshotService.volumeSummary()
            DispatchQueue.main.async {
                volume = summary
                if let message = result.errorMessage {
                    snapshots = []
                    status = .failed(message)
                } else {
                    snapshots = result.snapshots
                    status = .ready
                }
            }
        }
    }

    private func performDelete(tokens: [String]) {
        guard !tokens.isEmpty, !isBusy else { return }
        status = .deleting
        lastOutcome = nil

        // Find the disks first. A bad plan should not ask for a password.
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = SnapshotService.deletionPlan(dateTokens: tokens)
            DispatchQueue.main.async {
                if let message = plan.error {
                    status = .failed(message)
                    return
                }
                guard let script = plan.script, let count = plan.deletedCount else {
                    status = .failed("No snapshots selected.")
                    return
                }
                beginAuthorizedDelete(script: script, count: count)
            }
        }
    }

    private func beginAuthorizedDelete(script: String, count: Int) {
        let launch: (Bool) -> Void = { authorize in
            let freeBefore = SnapshotService.freeBytes()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = SnapshotService.runDeletion(
                    script: script,
                    deletedCount: count,
                    authorize: authorize
                )
                DispatchQueue.main.async {
                    self.handleDeleteResult(result, freeBefore: freeBefore)
                }
            }
        }

        // The password dialog has to be on the main thread. osascript brings up
        // its own dialog and can run off the main thread.
        if SnapshotService.prefersSessionAuthorization {
            switch PrivilegedSession.shared.ensureAuthorized() {
            case .cancelled:
                sessionAuthorized = SnapshotService.hasSessionAuthorization
                status = .cancelled
            case .failed(let message):
                sessionAuthorized = SnapshotService.hasSessionAuthorization
                status = .failed(message)
            case .success:
                sessionAuthorized = true
                launch(false)
            }
        } else {
            launch(true)
        }
    }

    private func handleDeleteResult(_ result: SnapshotService.OpResult, freeBefore: Int64?) {
        switch result {
        case .success(let partial):
            sessionAuthorized = SnapshotService.hasSessionAuthorization
            status = .measuring
            selection.removeAll()
            let deletedCount = partial.deletedCount

            DispatchQueue.global(qos: .userInitiated).async {
                let freeAfter = SnapshotService.freeBytesAfterDelete(baseline: freeBefore)
                let listResult = SnapshotService.listSnapshots()
                let summary = SnapshotService.volumeSummary()
                let outcome = SnapshotService.makeOutcome(
                    deletedCount: deletedCount,
                    freeBefore: freeBefore,
                    freeAfter: freeAfter
                )
                DispatchQueue.main.async {
                    lastOutcome = outcome
                    sessionAuthorized = SnapshotService.hasSessionAuthorization
                    if let reclaimed = outcome.reclaimedBytes, reclaimed > 0 {
                        sessionFreedBytes += reclaimed
                    }
                    volume = summary
                    snapshots = listResult.snapshots
                    if let message = listResult.errorMessage {
                        status = .failed("\(outcome.successMessage). Refresh failed: \(message)")
                    } else {
                        status = .success(outcome.successMessage)
                    }
                }
            }
        case .cancelled:
            sessionAuthorized = SnapshotService.hasSessionAuthorization
            status = .cancelled
        case .failed(let message):
            sessionAuthorized = SnapshotService.hasSessionAuthorization
            status = .failed(message)
        }
    }
}
