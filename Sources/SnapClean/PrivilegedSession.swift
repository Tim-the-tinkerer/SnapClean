import Darwin
import Foundation
import Security

/// Session-scoped administrator authorization for running tools as root.
///
/// **Does not store the password.** On first use, macOS shows the standard
/// authentication dialog. The resulting `AuthorizationRef` is kept in memory
/// until the app quits (or ``invalidate()``), so further deletes in this process
/// usually do not re-prompt (system policy may still expire rights).
///
/// `AuthorizationExecuteWithPrivileges` is deprecated and marked unavailable in
/// Swift, so it is resolved at runtime via `dlsym` from Security.framework.
final class PrivilegedSession {
    static let shared = PrivilegedSession()

    private var authRef: AuthorizationRef?
    /// True after a successful interactive authorization this process lifetime.
    private(set) var isAuthorized = false

    /// C function type for the deprecated execute-with-privileges API.
    private typealias ExecuteWithPrivilegesFn = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private lazy var executeWithPrivileges: ExecuteWithPrivilegesFn? = {
        // Prefer the Security framework dylib; fall back to the process namespace.
        let paths = [
            "/System/Library/Frameworks/Security.framework/Security",
            nil as String?,
        ]
        for path in paths {
            let handle: UnsafeMutableRawPointer?
            if let path {
                handle = dlopen(path, RTLD_LAZY)
            } else {
                handle = dlopen(nil, RTLD_LAZY)
            }
            guard let handle else { continue }
            guard let sym = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { continue }
            return unsafeBitCast(sym, to: ExecuteWithPrivilegesFn.self)
        }
        return nil
    }()

    private init() {}

    deinit {
        invalidate()
    }

    /// Drops cached authorization; the next privileged call will prompt again.
    func invalidate() {
        if let authRef {
            AuthorizationFree(authRef, [.destroyRights])
        }
        self.authRef = nil
        isAuthorized = false
    }

    enum RunResult: Equatable {
        case success(String)
        case cancelled
        case failed(String)
    }

    /// Ensures an authorization session exists (may show the password dialog).
    ///
    /// **Threading:** Prefer the main thread so the auth UI is attached correctly.
    @discardableResult
    func ensureAuthorized() -> RunResult {
        if authRef == nil {
            var ref: AuthorizationRef?
            let createStatus = AuthorizationCreate(nil, nil, [], &ref)
            guard createStatus == errAuthorizationSuccess, let ref else {
                return .failed("Could not create an authorization session (error \(createStatus)).")
            }
            authRef = ref
        }

        guard let authRef else {
            return .failed("Authorization session is missing.")
        }

        // kAuthorizationRightExecute must outlive AuthorizationCopyRights.
        return kAuthorizationRightExecute.withCString { namePtr in
            var item = AuthorizationItem(
                name: namePtr,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [
                    .interactionAllowed,
                    .extendRights,
                    .preAuthorize,
                ]
                let status = AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
                switch status {
                case errAuthorizationSuccess:
                    isAuthorized = true
                    return .success("")
                case errAuthorizationCanceled:
                    return .cancelled
                default:
                    isAuthorized = false
                    return .failed(authorizationErrorMessage(status))
                }
            }
        }
    }

    /// Runs `toolPath` as root with `arguments` (extra argv entries, not including the path).
    /// Calls ``ensureAuthorized()`` first.
    ///
    /// **Threading:** Call from the main thread.
    func run(toolPath: String, arguments: [String]) -> RunResult {
        switch ensureAuthorized() {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        case .success:
            break
        }

        guard let authRef else {
            return .failed("Authorization session is missing.")
        }
        guard FileManager.default.fileExists(atPath: toolPath) else {
            return .failed("Could not find \(toolPath).")
        }
        guard let execute = executeWithPrivileges else {
            return .failed("Privileged execution is not available on this Mac.")
        }

        // Build a classic C argv: pointers + trailing NULL.
        let cStrings: [UnsafeMutablePointer<CChar>] = arguments.map { strdup($0)! }
        defer {
            for ptr in cStrings {
                free(ptr)
            }
        }

        var pipe: UnsafeMutablePointer<FILE>?
        let status: OSStatus = {
            var argvStorage: [UnsafeMutablePointer<CChar>?] = cStrings.map { Optional($0) }
            argvStorage.append(nil)

            return argvStorage.withUnsafeMutableBufferPointer { buffer in
                let raw = UnsafeMutableRawPointer(buffer.baseAddress!)
                let argv = UnsafePointer(raw.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self))
                return toolPath.withCString { pathC in
                    execute(
                        authRef,
                        pathC,
                        [],
                        argv,
                        &pipe
                    )
                }
            }
        }()

        switch status {
        case errAuthorizationSuccess:
            let output = drain(pipe: pipe)
            return .success(output)
        case errAuthorizationCanceled:
            isAuthorized = false
            if let pipe { fclose(pipe) }
            return .cancelled
        default:
            if let pipe { fclose(pipe) }
            if status == errAuthorizationDenied || status == errAuthorizationInvalidRef {
                isAuthorized = false
            }
            return .failed(authorizationErrorMessage(status))
        }
    }

    /// Runs a shell script as root via `/bin/sh -c`.
    /// Script must be fully trusted (caller validates all interpolated tokens).
    /// Appends a success marker so we know the script finished (exit status is not exposed).
    func runShell(_ script: String) -> RunResult {
        let wrapped = """
        \(script)
        echo SNAPCLEAN_OK
        """
        switch run(toolPath: "/bin/sh", arguments: ["-c", wrapped]) {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        case .success(let output):
            if output.contains("SNAPCLEAN_OK") {
                return .success(output)
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .failed("Privileged command did not complete successfully.")
            }
            return .failed(trimmed)
        }
    }

    private func drain(pipe: UnsafeMutablePointer<FILE>?) -> String {
        guard let pipe else { return "" }
        defer { fclose(pipe) }

        let fd = fileno(pipe)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func authorizationErrorMessage(_ status: OSStatus) -> String {
        switch status {
        case errAuthorizationDenied:
            return "Authorization denied."
        case errAuthorizationCanceled:
            return "Cancelled."
        case errAuthorizationToolExecuteFailure:
            return "Could not run the privileged tool."
        case errAuthorizationToolEnvironmentError:
            return "Privileged tool environment error."
        case errAuthorizationInteractionNotAllowed:
            return "Authentication UI is not allowed in this context."
        default:
            return "Authorization failed (error \(status))."
        }
    }
}
