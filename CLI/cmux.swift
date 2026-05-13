import Foundation
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

struct CLIError: Error, CustomStringConvertible {
    let message: String
    let exitCode: Int32

    init(message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    var description: String { message }
}

private enum CLISocketEnvironment {
    static func socketPath(in environment: [String: String]) throws -> String? {
        let socketPath = normalized(environment["CMUX_SOCKET_PATH"])
        let legacySocketPath = normalized(environment["CMUX_SOCKET"])
        if let socketPath, let legacySocketPath, socketPath != legacySocketPath {
            throw CLIError(message: "Refusing to choose socket: CMUX_SOCKET_PATH and CMUX_SOCKET differ. Use CMUX_SOCKET_PATH or unset CMUX_SOCKET.")
        }
        return socketPath ?? legacySocketPath
    }

    static func socketPathForTelemetry(in environment: [String: String]) -> String? {
        normalized(environment["CMUX_SOCKET_PATH"]) ?? normalized(environment["CMUX_SOCKET"])
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class CLISocketSentryTelemetry {
    private struct PendingBreadcrumb {
        let message: String
        let data: [String: Any]
    }

    private let command: String
    private let subcommand: String
    private let socketPath: String
    private let envSocketPath: String?
    private let workspaceId: String?
    private let surfaceId: String?
    private let disabledByEnv: Bool
    private var pendingBreadcrumbs: [PendingBreadcrumb] = []

#if canImport(Sentry)
    private static let startupLock = NSLock()
    private static var started = false
    private static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"

    private static func currentSentryReleaseName() -> String? {
        guard let bundleIdentifier = currentSentryBundleIdentifier(),
              let version = currentBundleVersionValue(forKey: "CFBundleShortVersionString"),
              let build = currentBundleVersionValue(forKey: "CFBundleVersion")
        else {
            return nil
        }
        return "\(bundleIdentifier)@\(version)+\(build)"
    }

    private static func currentSentryBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = currentSentryBundle()?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private static func currentBundleVersionValue(forKey key: String) -> String? {
        guard let value = currentSentryBundle()?.infoDictionary?[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func currentSentryBundle() -> Bundle? {
        if Bundle.main.bundleIdentifier?.isEmpty == false {
            return Bundle.main
        }

        guard let executableURL = currentExecutableURL() else {
            return Bundle.main
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app", let bundle = Bundle(url: current) {
                return bundle
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app", let bundle = Bundle(url: appURL) {
                    return bundle
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return Bundle.main
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
            }
        }

        return Bundle.main.executableURL?.standardizedFileURL
    }

    private static func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }
#endif

    init(command: String, commandArgs: [String], socketPath: String, processEnv: [String: String]) {
        self.command = command.lowercased()
        self.subcommand = commandArgs.first?.lowercased() ?? "help"
        self.socketPath = socketPath
        self.envSocketPath = CLISocketEnvironment.socketPathForTelemetry(in: processEnv)
        self.workspaceId = processEnv["CMUX_WORKSPACE_ID"]
        self.surfaceId = processEnv["CMUX_SURFACE_ID"]
        self.disabledByEnv =
            processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||
            processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1"
    }

    func breadcrumb(_ message: String, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        pendingBreadcrumbs.append(PendingBreadcrumb(message: message, data: data))
#endif
    }

    func captureError(stage: String, error: Error, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        Self.ensureStarted()
        flushPendingBreadcrumbs()
        var context = baseContext()
        context["stage"] = stage
        context["error"] = String(describing: error)
        for (key, value) in socketDiagnostics() {
            context[key] = value
        }
        for (key, value) in data {
            context[key] = value
        }
        let subcommand = self.subcommand
        let command = self.command
        _ = SentrySDK.capture(error: error) { scope in
            scope.setLevel(.error)
            scope.setTag(value: "cmux-cli", key: "component")
            scope.setTag(value: command, key: "cli_command")
            scope.setTag(value: subcommand, key: "cli_subcommand")
            scope.setContext(value: context, key: "cli_socket")
        }
        SentrySDK.flush(timeout: 2.0)
#endif
    }

    private var shouldEmit: Bool {
        !disabledByEnv
    }

#if canImport(Sentry)
    private func flushPendingBreadcrumbs() {
        for pending in pendingBreadcrumbs {
            addBreadcrumb(message: pending.message, data: pending.data)
        }
        pendingBreadcrumbs.removeAll()
    }

    private func addBreadcrumb(message: String, data: [String: Any]) {
        var payload = baseContext()
        for (key, value) in data {
            payload[key] = value
        }
        let crumb = Breadcrumb(level: .info, category: "cmux.cli")
        crumb.message = message
        crumb.data = payload
        SentrySDK.addBreadcrumb(crumb)
    }
#endif

    private func baseContext() -> [String: Any] {
        var context: [String: Any] = [
            "command": command,
            "subcommand": subcommand,
            "requested_socket_path": socketPath,
            "env_socket_path": envSocketPath ?? "<unset>"
        ]
        if let workspaceId {
            context["workspace_id"] = workspaceId
        }
        if let surfaceId {
            context["surface_id"] = surfaceId
        }
        return context
    }

    private func socketDiagnostics() -> [String: Any] {
        var context: [String: Any] = [
            "cwd": FileManager.default.currentDirectoryPath,
            "uid": Int(getuid()),
            "euid": Int(geteuid())
        ]

        var st = stat()
        if lstat(socketPath, &st) == 0 {
            context["socket_exists"] = true
            context["socket_mode"] = String(format: "%o", Int(st.st_mode & 0o7777))
            context["socket_owner_uid"] = Int(st.st_uid)
            context["socket_owner_gid"] = Int(st.st_gid)
            context["socket_file_type"] = Self.fileTypeDescription(mode: st.st_mode)
        } else {
            let code = errno
            context["socket_exists"] = false
            context["socket_errno"] = Int(code)
            context["socket_errno_description"] = String(cString: strerror(code))
        }

        let tmpSockets = Self.discoverSockets(in: "/tmp", limit: 10)
        if !tmpSockets.isEmpty {
            context["tmp_cmux_sockets"] = tmpSockets
        }
        let taggedSockets = tmpSockets.filter { $0 != CLISocketPathResolver.legacyDefaultSocketPath }
        if CLISocketPathResolver.isImplicitDefaultPath(socketPath),
           (envSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           !taggedSockets.isEmpty {
            context["possible_root_cause"] = "CMUX_SOCKET_PATH missing while tagged sockets exist"
        }

        return context
    }

    private static func fileTypeDescription(mode: mode_t) -> String {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFSOCK):
            return "socket"
        case mode_t(S_IFREG):
            return "regular"
        case mode_t(S_IFDIR):
            return "directory"
        case mode_t(S_IFLNK):
            return "symlink"
        default:
            return "other"
        }
    }

    private static func discoverSockets(in directory: String, limit: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var sockets: [String] = []
        for name in entries.sorted() {
            guard name.hasPrefix("cmux"), name.hasSuffix(".sock") else { continue }
            let fullPath = URL(fileURLWithPath: directory)
                .appendingPathComponent(name, isDirectory: false)
                .path
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
            sockets.append(fullPath)
            if sockets.count >= limit {
                break
            }
        }
        return sockets
    }

#if canImport(Sentry)
    private static func ensureStarted() {
        startupLock.lock()
        defer { startupLock.unlock() }
        guard !started else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = currentSentryReleaseName()
#if DEBUG
            options.environment = "development-cli"
#else
            options.environment = "production-cli"
#endif
            options.debug = false
            options.sendDefaultPii = true
            options.attachStacktrace = true
            options.tracesSampleRate = 0.0
            options.enableAppHangTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableAutoSessionTracking = false
            options.enableCaptureFailedRequests = false
            options.enableMetricKit = false
        }
        started = true
    }
#endif
}

struct WindowInfo {
    let index: Int
    let id: String
    let key: Bool
    let selectedWorkspaceId: String?
    let workspaceCount: Int
}

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

private enum TopSortKey: Equatable {
    case cpu
    case rss
    case proc
}

private enum TopTextFormat: Equatable {
    case tree
    case tsv
}

enum SocketPasswordResolver {
    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"
    private static let directoryName = "cmux"
    private static let fileName = "socket-control-password"

    static func resolve(explicit: String?, socketPath: String) -> String? {
        if let explicit = normalized(explicit) {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"]) {
            return env
        }
        if let filePassword = loadFromFile() {
            return filePassword
        }
        return loadFromKeychain(socketPath: socketPath)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromFile() -> String? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let passwordURL = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: passwordURL) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let tag = normalized(environment["CMUX_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    private static func loadFromKeychain(socketPath: String) -> String? {
        for service in keychainServices(socketPath: socketPath) {
            let authContext = LAContext()
            authContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess else {
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        return nil
    }
}

private enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

private enum CLISocketPathResolver {
    private static let appSupportDirectoryName = "cmux"
    private static let stableSocketFileName = "cmux.sock"
    private static let lastSocketPathFileName = "last-socket-path"
    static let legacyDefaultSocketPath = "/tmp/cmux.sock"
    private static let fallbackSocketPath = "/tmp/cmux-debug.sock"
    private static let stagingSocketPath = "/tmp/cmux-staging.sock"
    private static let legacyLastSocketPathFile = "/tmp/cmux-last-socket-path"

    static var defaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        path == defaultSocketPath || path == legacyDefaultSocketPath
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(requestedPath: requestedPath, environment: environment))

        // Prefer sockets that are currently accepting connections.
        for path in candidates where canConnect(to: path) {
            return path
        }

        // If the listener is still starting, prefer existing socket files.
        for path in candidates where isSocketFile(path) {
            return path
        }

        return requestedPath
    }

    private static func candidatePaths(requestedPath: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []

        if let tag = normalized(environment["CMUX_TAG"]) {
            let slug = sanitizeTagSlug(tag)
            candidates.append("/tmp/cmux-debug-\(slug).sock")
            candidates.append("/tmp/cmux-\(slug).sock")
        }

        candidates.append(requestedPath)
        candidates.append(defaultSocketPath)
        candidates.append(legacyDefaultSocketPath)
        candidates.append(fallbackSocketPath)
        candidates.append(stagingSocketPath)
        candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        if let last = readLastSocketPath() {
            candidates.append(last)
        }
        return candidates
    }

    private static func readLastSocketPath() -> String? {
        let primaryCandidate: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
            .path
        let candidates = [primaryCandidate, legacyLastSocketPathFile].compactMap { $0 }

        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data) {
                return value
            }
        }
        return nil
    }

    private static func discoverTaggedSockets(limit: Int) -> [String] {
        var discovered: [(path: String, mtime: TimeInterval)] = []
        for directory in socketDiscoveryDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            discovered.reserveCapacity(min(limit, discovered.count + entries.count))
            for name in entries where name.hasPrefix("cmux") && name.hasSuffix(".sock") {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if path == defaultSocketPath || path == legacyDefaultSocketPath || path == fallbackSocketPath || path == stagingSocketPath {
                    continue
                }
                let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
                discovered.append((path: path, mtime: modified))
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return dedupe(discovered.prefix(limit).map(\.path))
    }

    private static func isSocketFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private static func canConnect(to path: String) -> Bool {
        guard isSocketFile(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : slug
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableSocketDirectoryURL() -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    private static func socketDiscoveryDirectories() -> [String] {
        let appSupportSocketDirectory: String = stableSocketDirectoryURL()?.path ?? ""
        return dedupe([
            "/tmp",
            appSupportSocketDirectory,
        ])
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }
}

final class SocketClient {
    private struct RelayEndpoint {
        let host: String
        let port: UInt16
    }

    private struct RelayCredentials {
        let relayID: String
        let relayToken: Data
    }

    private let path: String
    private var socketFD: Int32 = -1
    private var lastConfiguredReceiveTimeout: TimeInterval?
    private var lastOperationTelemetry: CLISocketOperationTelemetry.State?
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    private static let maxSocketTimeoutSeconds: TimeInterval = 9_007_199_254_740_991
    private static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
           let seconds = Double(raw),
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }
        return defaultResponseTimeoutSeconds
    }()

    private static func isCompleteSingleLineResponse(_ data: Data) -> Bool {
        guard data.contains(UInt8(0x0A)),
              let response = String(data: data, encoding: .utf8) else {
            return false
        }
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("\n") else {
            return false
        }

        if normalized == "OK" ||
            normalized == "PONG" ||
            normalized.hasPrefix("OK ") ||
            normalized.hasPrefix("ERROR:") {
            return true
        }

        if let jsonData = normalized.data(using: .utf8), (try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])) != nil {
            return true
        }

        return false
    }

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    var isRelayBacked: Bool {
        relayEndpoint != nil
    }

    func connectionAppearsOpen() -> Bool {
        if relayEndpoint != nil, socketFD < 0 {
            do {
                try connect()
            } catch {
                return false
            }
        }
        guard socketFD >= 0 else { return false }
        while true {
            var descriptor = pollfd(
                fd: socketFD,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let ready = Darwin.poll(&descriptor, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            let terminalEvents = Int16(POLLHUP | POLLERR | POLLNVAL)
            return descriptor.revents & terminalEvents == 0
        }
    }

    func operationTelemetryContext() -> [String: Any] {
        lastOperationTelemetry?.context() ?? [:]
    }

    func hasUnfinishedOperationTelemetry() -> Bool { lastOperationTelemetry.map { $0.phase != .completed } ?? false }

    private var relayEndpoint: RelayEndpoint? {
        Self.parseRelayEndpoint(path)
    }

    private static func trimmedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func socketTimeval(for timeout: TimeInterval) -> timeval {
        let sanitizedTimeout = timeout.isFinite ? timeout : defaultResponseTimeoutSeconds
        let clampedTimeout = min(max(sanitizedTimeout, 0.01), maxSocketTimeoutSeconds)
        let seconds = floor(clampedTimeout)
        let microseconds = min(
            max(Int((clampedTimeout - seconds) * 1_000_000), 0),
            999_999
        )
        return timeval(
            tv_sec: Int(seconds),
            tv_usec: __darwin_suseconds_t(microseconds)
        )
    }

    private func recordOperation(_ operation: CLISocketOperationTelemetry.State) {
        lastOperationTelemetry = operation
    }

    func connect() throws {
        if socketFD >= 0 { return }
        try connectOnce()
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        lastConfiguredReceiveTimeout = nil
    }

    func send(command: String, responseTimeout: TimeInterval? = nil) throws -> String {
        if relayEndpoint != nil, socketFD < 0 {
            try connect()
        }
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let shouldCloseAfterSend = relayEndpoint != nil
        defer {
            if shouldCloseAfterSend {
                close()
            }
        }

        let initialResponseTimeout = responseTimeout ?? Self.responseTimeoutSeconds
        if lastConfiguredReceiveTimeout != initialResponseTimeout {
            try configureReceiveTimeout(initialResponseTimeout)
        }
        var operation = CLISocketOperationTelemetry.State(
            name: CLISocketOperationTelemetry.operationName(for: command),
            timeout: initialResponseTimeout,
            startedAt: Date(),
            phase: .writeRequest
        )
        recordOperation(operation)

        let payload = command + "\n"
        try writeAll(
            Data(payload.utf8),
            timeoutMessage: "Command timed out",
            failureMessage: "Failed to write to socket"
        )

        var data = Data()
        var sawNewline = false
        var receivedCompleteResponse = false

        while true {
            let currentTimeout = sawNewline ? Self.multilineResponseIdleTimeoutSeconds : initialResponseTimeout
            operation.phase = sawNewline ? .readMultilineResponse : .waitForResponse
            operation.sawNewline = sawNewline
            operation.timeout = currentTimeout
            recordOperation(operation)
            if lastConfiguredReceiveTimeout != currentTimeout {
                try configureReceiveTimeout(currentTimeout)
            }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        receivedCompleteResponse = true
                        break
                    }
                    throw CLIError(message: "Command timed out")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                operation.sawNewline = sawNewline
                recordOperation(operation)
                if data.isEmpty {
                    throw CLIError(message: "Socket closed before reply")
                }
                if !sawNewline {
                    throw CLIError(message: "Socket closed before complete reply")
                }
                receivedCompleteResponse = true
                break
            }
            data.append(buffer, count: count)
            operation.bytesRead += count
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
                if Self.isCompleteSingleLineResponse(data) {
                    receivedCompleteResponse = true
                    break
                }
            }
        }

        operation.sawNewline = sawNewline
        if receivedCompleteResponse {
            operation.phase = .completed
        }
        recordOperation(operation)

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    private func connectOnce() throws {
        if let relayEndpoint {
            try connectToRelay(endpoint: relayEndpoint)
            return
        }

        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
            try configureReceiveTimeout(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw CLIError(
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    private static func parseRelayEndpoint(_ raw: String) -> RelayEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/") else {
            return nil
        }
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let port = UInt16(components[1]),
              port > 0 else {
            return nil
        }
        let host = String(components[0]).lowercased()
        guard host == "127.0.0.1" || host == "localhost" else {
            return nil
        }
        return RelayEndpoint(host: host == "localhost" ? "127.0.0.1" : host, port: port)
    }

    private static func relayCredentials(for endpoint: RelayEndpoint) throws -> RelayCredentials {
        let environment = ProcessInfo.processInfo.environment
        if let relayID = trimmedEnvValue(environment["CMUX_RELAY_ID"]),
           let relayTokenHex = trimmedEnvValue(environment["CMUX_RELAY_TOKEN"]),
           let relayToken = hexData(from: relayTokenHex) {
            return RelayCredentials(relayID: relayID, relayToken: relayToken)
        }

        let authURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmux/relay/\(endpoint.port).auth", isDirectory: false)
        guard let authData = try? Data(contentsOf: authURL),
              let authObject = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let relayID = trimmedEnvValue(authObject["relay_id"] as? String),
              let relayTokenHex = trimmedEnvValue(authObject["relay_token"] as? String),
              let relayToken = hexData(from: relayTokenHex) else {
            throw CLIError(message: "Missing relay auth metadata for \(endpoint.host):\(endpoint.port)")
        }

        return RelayCredentials(relayID: relayID, relayToken: relayToken)
    }

    private static func hexData(from string: String) -> Data? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let byte = UInt8(normalized[cursor..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            cursor = next
        }
        return data
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func connectToRelay(endpoint: RelayEndpoint) throws {
        let credentials = try Self.relayCredentials(for: endpoint)

        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CLIError(message: "Failed to create relay socket")
        }
        do {
            try configureSocketWriteSafety(Self.responseTimeoutSeconds)
            try configureReceiveTimeout(Self.responseTimeoutSeconds)
        } catch {
            close()
            throw error
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        let parsedAddress = withUnsafeMutablePointer(to: &address.sin_addr) { pointer in
            endpoint.host.withCString { hostPointer in
                inet_pton(AF_INET, hostPointer, pointer)
            }
        }
        guard parsedAddress == 1 else {
            close()
            throw CLIError(message: "Invalid relay endpoint \(endpoint.host):\(endpoint.port)")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if result != 0 {
            let connectErrno = errno
            close()
            throw CLIError(
                message: "Failed to connect to relay at \(endpoint.host):\(endpoint.port) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
            )
        }

        do {
            try authenticateRelay(credentials: credentials)
        } catch {
            close()
            throw error
        }
    }

    private func authenticateRelay(credentials: RelayCredentials) throws {
        let challengeLine = try readLine()
        guard let challengeData = challengeLine.data(using: .utf8),
              let challenge = try JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              (challenge["protocol"] as? String) == "cmux-relay-auth",
              let version = challenge["version"] as? Int,
              let relayID = challenge["relay_id"] as? String,
              relayID == credentials.relayID,
              let nonce = challenge["nonce"] as? String,
              !nonce.isEmpty else {
            throw CLIError(message: "Invalid relay authentication challenge")
        }

        let authMessage = Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        let key = SymmetricKey(data: credentials.relayToken)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: key))
        let authPayload = try JSONSerialization.data(withJSONObject: [
            "relay_id": relayID,
            "mac": Self.hexString(from: mac),
        ])
        try writeAll(
            authPayload + Data([0x0A]),
            timeoutMessage: "Relay command timed out",
            failureMessage: "Failed to write to relay socket"
        )

        let authResponseLine = try readLine()
        guard let authResponseData = authResponseLine.data(using: .utf8),
              let authResponse = try JSONSerialization.jsonObject(with: authResponseData) as? [String: Any],
              (authResponse["ok"] as? Bool) == true else {
            throw CLIError(message: "Relay authentication failed")
        }
    }

    private func writeAll(
        _ data: Data,
        timeoutMessage: String,
        failureMessage: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    let errorCode = errno
                    if errorCode == EINTR {
                        continue
                    }
                    close()
                    if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == ETIMEDOUT {
                        throw CLIError(message: timeoutMessage)
                    }
                    let reason = String(cString: strerror(errorCode))
                    throw CLIError(
                        message: "\(failureMessage) (\(reason), errno \(errorCode))"
                    )
                }
                if written == 0 {
                    close()
                    throw CLIError(message: failureMessage)
                }
                offset += written
            }
        }
    }

    private func configureSocketWriteSafety(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let sendTimeoutResult = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendTimeoutResult == 0 else {
            throw CLIError(message: "Failed to configure socket write timeout")
        }

#if os(macOS)
        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard noSigPipeResult == 0 else {
            throw CLIError(message: "Failed to disable SIGPIPE on socket")
        }
#endif
    }

    private func readLine(maxBytes: Int = 16 * 1024) throws -> String {
        var data = Data()

        while data.count < maxBytes {
            try configureReceiveTimeout(Self.responseTimeoutSeconds)

            var byte: UInt8 = 0
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: "Relay command timed out")
                }
                throw CLIError(message: "Relay socket read error")
            }
            if count == 0 {
                break
            }
            if byte == 0x0A {
                break
            }
            data.append(byte)
        }

        guard !data.isEmpty else {
            throw CLIError(message: "Unexpected EOF from relay")
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 relay response")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureReceiveTimeout(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            let errorCode = errno
            let reason = String(cString: strerror(errorCode))
            throw CLIError(message: "Failed to configure socket receive timeout (\(reason), errno \(errorCode))")
        }
        lastConfiguredReceiveTimeout = timeout
    }

    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        let client = SocketClient(path: path)
        if (try? client.connect()) != nil {
            if client.relayEndpoint != nil {
                client.close()
            }
            return client
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "cmux app did not start in time (socket not found at \(path))")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "cmux app did not start in time (socket not found at \(path))")
        }

        let queue = DispatchQueue(label: "com.cmux.cli.socket-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func attemptConnect() {
            guard !connected else { return }
            if (try? client.connect()) != nil {
                connected = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            attemptConnect()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            attemptConnect()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            client.close()
            throw CLIError(message: "cmux app did not start in time (socket not found at \(path))")
        }

        source.cancel()
        return client
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.cmux.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    func sendV2(
        method: String,
        params: [String: Any] = [:],
        responseTimeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw = try send(command: requestLine, responseTimeout: responseTimeout)

        // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
        // before the JSON protocol starts. Surface these directly instead of letting
        // JSONSerialization throw a confusing parse error.
        if raw.hasPrefix("ERROR:") {
            throw CLIError(message: raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw CLIError(message: "Invalid v2 response: \(raw)")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            throw CLIError(message: "\(code): \(message)")
        }

        throw CLIError(message: "v2 request failed")
    }

    func streamV2(
        method: String,
        params: [String: Any] = [:],
        onLine: (String) throws -> Void
    ) throws {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let requestData = try? JSONSerialization.data(withJSONObject: request, options: []),
              let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 stream request")
        }

        try writeAll(
            Data((requestLine + "\n").utf8),
            timeoutMessage: "Stream request timed out",
            failureMessage: "Failed to write stream request"
        )

        while true {
            let line = try readStreamLine()
            try onLine(line)
        }
    }

    private func readStreamLine(maxBytes: Int = 4 * 1024 * 1024) throws -> String {
        var data = Data()
        try configureReceiveTimeout(45)
        while data.count < maxBytes {
            var byte: UInt8 = 0
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: "Timed out waiting for event stream frame")
                }
                throw CLIError(message: "Event stream socket read error")
            }
            if count == 0 {
                throw CLIError(message: "Event stream closed")
            }
            if byte == 0x0A {
                guard let line = String(data: data, encoding: .utf8) else {
                    throw CLIError(message: "Invalid UTF-8 event stream frame")
                }
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            data.append(byte)
        }
        throw CLIError(message: "Event stream frame exceeded \(maxBytes) bytes")
    }
}

struct CMUXCLI {
    let args: [String]

    private static let debugLastSocketHintPath = "/tmp/cmux-last-socket-path"
    private static let vmCreateIdempotencyTTLSeconds: TimeInterval = 10 * 60
    private static let vmCreateResponseTimeoutSeconds: TimeInterval = 16 * 60
    private static let vmAttachResponseTimeoutSeconds: TimeInterval = 16 * 60

    private func captureSocketTransportError(telemetry: CLISocketSentryTelemetry, stage: String, error: Error, client: SocketClient) {
        if client.hasUnfinishedOperationTelemetry() {
            telemetry.captureError(stage: stage, error: error, data: client.operationTelemetryContext())
        }
    }

    private struct VMCreateIdempotencyStore: Codable {
        var records: [String: VMCreateIdempotencyRecord] = [:]
    }

    private struct VMCreateIdempotencyRecord: Codable {
        let key: String
        let createdAt: TimeInterval
    }

    private struct ActiveVMCreateIdempotency {
        let signature: String
        let key: String
    }

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func vmCreateIdempotencySignature(image: String?, provider: String?) -> String {
        let normalizedImage = image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedProvider = provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return "image=\(normalizedImage)\u{1f}provider=\(normalizedProvider)"
    }

    private static func normalizedVMProvider(_ provider: String?) throws -> String? {
        guard let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let normalized = trimmed.lowercased()
        guard normalized == "e2b" || normalized == "freestyle" else {
            throw CLIError(message: "vm new: unsupported provider '\(trimmed)'. Expected e2b or freestyle.")
        }
        return normalized
    }

    private static func vmCreateIdempotencyStoreURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-create-idempotency.json", isDirectory: false)
    }

    private static func loadVMCreateIdempotencyStore(from url: URL) -> VMCreateIdempotencyStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(VMCreateIdempotencyStore.self, from: data) else {
            return VMCreateIdempotencyStore()
        }
        return store
    }

    private static func saveVMCreateIdempotencyStore(_ store: VMCreateIdempotencyStore, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func activeVMCreateIdempotency(image: String?, provider: String?) throws -> ActiveVMCreateIdempotency {
        let url = vmCreateIdempotencyStoreURL()
        let signature = vmCreateIdempotencySignature(image: image, provider: provider)
        let now = Date().timeIntervalSince1970
        var store = loadVMCreateIdempotencyStore(from: url)
        store.records = store.records.filter { _, record in
            !record.key.isEmpty && now - record.createdAt < vmCreateIdempotencyTTLSeconds
        }
        if let existing = store.records[signature] {
            try saveVMCreateIdempotencyStore(store, to: url)
            return ActiveVMCreateIdempotency(signature: signature, key: existing.key)
        }
        let key = UUID().uuidString.lowercased()
        store.records[signature] = VMCreateIdempotencyRecord(key: key, createdAt: now)
        try saveVMCreateIdempotencyStore(store, to: url)
        return ActiveVMCreateIdempotency(signature: signature, key: key)
    }

    private static func clearVMCreateIdempotency(_ active: ActiveVMCreateIdempotency) {
        let url = vmCreateIdempotencyStoreURL()
        var store = loadVMCreateIdempotencyStore(from: url)
        guard store.records[active.signature]?.key == active.key else { return }
        store.records.removeValue(forKey: active.signature)
        try? saveVMCreateIdempotencyStore(store, to: url)
    }

    private static func pathIsSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func debugSocketPathFromHintFile() -> String? {
#if DEBUG
        guard let raw = try? String(contentsOfFile: debugLastSocketHintPath, encoding: .utf8) else {
            return nil
        }
        guard let hinted = normalizedEnvValue(raw),
              hinted.hasPrefix("/tmp/cmux-debug"),
              hinted.hasSuffix(".sock"),
              pathIsSocket(hinted) else {
            return nil
        }
        return hinted
#else
        return nil
#endif
    }

    private static func defaultSocketPath(environment: [String: String]) -> String {
        if let explicit = normalizedEnvValue(environment["CMUX_SOCKET_PATH"]) {
            return explicit
        }
#if DEBUG
        if let hinted = debugSocketPathFromHintFile() {
            return hinted
        }
        return "/tmp/cmux-debug.sock"
#else
        return "/tmp/cmux.sock"
#endif
    }

    private static let browserDisabledDefaultsKey = "browserDisabledOverride"
    private static let defaultBrowserSettingsDomain = "com.cmuxterm.app"

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            return Bundle.main.executableURL?.standardizedFileURL
        }

        var buffer = Array<CChar>(repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return Bundle.main.executableURL?.standardizedFileURL
        }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
    }

    private static func containingAppBundleIdentifier() -> String? {
        guard let executableURL = currentExecutableURL() else { return nil }
        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app",
               let bundle = Bundle(url: current),
               let bundleIdentifier = normalizedEnvValue(bundle.bundleIdentifier) {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundle = Bundle(url: appURL),
                   let bundleIdentifier = normalizedEnvValue(bundle.bundleIdentifier) {
                    return bundleIdentifier
                }
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            current = parent
        }
        return nil
    }

    private static func browserSettingsDomain(environment: [String: String]) -> String {
        normalizedEnvValue(environment["CMUX_BUNDLE_ID"])
        ?? containingAppBundleIdentifier()
        ?? defaultBrowserSettingsDomain
    }

    // Presentation flags are global, but command option values can also look like flags.
    private static let commandOptionsWithValues: Set<String> = [
        "--action", "--after-workspace", "--agent", "--amount", "--arch",
        "--attr", "--before-workspace", "--body", "--color", "--command",
        "--config", "--cwd", "--description", "--direction", "--domain",
        "--dx", "--dy", "--email", "--event", "--expires", "--focus",
        "--function", "--id", "--image", "--index", "--key", "--layout",
        "--lines", "--load-state", "--max-depth", "--name", "--os",
        "--out", "--pane", "--panel", "--path", "--profile", "--property",
        "--provider", "--relay-port", "--script", "--selector", "--session",
        "--source", "--subtitle", "--surface", "--tab", "--target-pane",
        "--text", "--timeout", "--timeout-ms", "--title", "--transcript",
        "--turn", "--type", "--url", "--url-contains", "--value", "--window",
        "--workspace",
    ]

    private func parsePresentationOptions(
        _ commandArgs: [String]
    ) throws -> (jsonOutput: Bool, idFormat: String?, remaining: [String]) {
        var jsonOutput = false
        var idFormat: String?
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if pastTerminator {
                remaining.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                index += 1
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormat = commandArgs[index + 1]
                index += 2
                continue
            }
            remaining.append(arg)
            if Self.commandOptionsWithValues.contains(arg), index + 1 < commandArgs.count {
                remaining.append(commandArgs[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return (jsonOutput, idFormat, remaining)
    }

    private func runBrowserAvailabilityCommand(
        command: String,
        commandArgs: [String],
        jsonOutput globalJSONOutput: Bool,
        environment: [String: String]
    ) throws {
        var effectiveJSONOutput = globalJSONOutput
        var args = commandArgs
        if let jsonIndex = args.firstIndex(of: "--json") {
            effectiveJSONOutput = true
            args.remove(at: jsonIndex)
        }

        let action: String
        if command == "browser" {
            guard let first = args.first?.lowercased() else {
                throw CLIError(message: "browser requires a subcommand")
            }
            action = first
            args = Array(args.dropFirst())
        } else {
            action = command
        }

        guard args.isEmpty else {
            throw CLIError(message: "Unexpected argument: \(args[0])")
        }

        let domain = Self.browserSettingsDomain(environment: environment)
        let defaults = UserDefaults(suiteName: domain) ?? .standard

        switch action {
        case "disable", "disable-browser":
            defaults.set(true, forKey: Self.browserDisabledDefaultsKey)
            defaults.synchronize()
        case "enable", "enable-browser":
            defaults.set(false, forKey: Self.browserDisabledDefaultsKey)
            defaults.synchronize()
        case "status", "browser-status":
            break
        default:
            throw CLIError(message: "Unknown browser availability command: \(action)")
        }

        let disabled = defaults.object(forKey: Self.browserDisabledDefaultsKey) == nil
            ? false
            : defaults.bool(forKey: Self.browserDisabledDefaultsKey)
        let payload: [String: Any] = [
            "enabled": !disabled,
            "disabled": disabled,
            "domain": domain,
            "key": Self.browserDisabledDefaultsKey
        ]
        if effectiveJSONOutput {
            print(jsonString(payload))
        } else if action == "status" || action == "browser-status" {
            print(disabled ? "disabled" : "enabled")
        } else {
            print(disabled ? "cmux browser disabled" : "cmux browser enabled")
        }
    }

    func run() throws {
        let processEnv = ProcessInfo.processInfo.environment
        var explicitSocketPath: String? = nil
        var jsonOutput = false
        var idFormatArg: String? = nil
        var windowId: String? = nil
        var socketPasswordArg: String? = nil

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--socket" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--socket requires a path")
                }
                explicitSocketPath = args[index + 1]
                index += 2
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormatArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "--window" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--window requires a window id")
                }
                windowId = args[index + 1]
                index += 2
                continue
            }
            if arg == "--password" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--password requires a value")
                }
                socketPasswordArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "-v" || arg == "--version" {
                print(versionSummary())
                return
            }
            if arg == "-h" || arg == "--help" {
                print(usage())
                return
            }
            break
        }

        guard index < args.count else {
            throw CLIError(
                message: "Missing command. Usage: cmux <path>|<command> [options]. Run 'cmux --help' for the full command list.",
                exitCode: 2
            )
        }

        let command = args[index]
        let presentationOptions = try parsePresentationOptions(Array(args[(index + 1)...]))
        if presentationOptions.jsonOutput {
            jsonOutput = true
        }
        if let parsedIDFormat = presentationOptions.idFormat {
            idFormatArg = parsedIDFormat
        }
        let commandArgs = presentationOptions.remaining

        if command == "version" {
            print(versionSummary())
            return
        }

        // Check for --help/-h on subcommands before resolving sockets,
        // so help text is available even when cmux is not running.
        let preSeparatorArgs = commandArgs.firstIndex(of: "--").map { commandArgs[..<$0] } ?? commandArgs[...]
        if command != "__tmux-compat",
           preSeparatorArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
            if dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {
                return
            }
            print("Unknown command '\(command)'. Run 'cmux help' to see available commands.")
            return
        }

        if command == "help" { print(usage()); return }
        if command == "docs" { try runDocsCommand(commandArgs: commandArgs, jsonOutput: jsonOutput); return }
        if command == "welcome" { printWelcome(); return }

        if command == "settings",
           settingsCommandDoesNotNeedSocket(commandArgs) {
            try runSettings(
                commandArgs: commandArgs,
                socketPath: CLISocketPathResolver.defaultSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        // Keep no-socket config subcommands on the early path. Socket-backed
        // config subcommands fall through to the resolved-socket dispatch below.
        if command == "config",
           configCommandDoesNotNeedSocket(commandArgs) {
            try runConfigCommand(
                commandArgs: commandArgs,
                socketPath: nil,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        let envSocketPath = explicitSocketPath == nil
            ? try CLISocketEnvironment.socketPath(in: processEnv)
            : CLISocketEnvironment.socketPathForTelemetry(in: processEnv)
        let socketPath = explicitSocketPath ?? envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let socketPathSource: CLISocketPathSource
        if explicitSocketPath != nil {
            socketPathSource = .explicitFlag
        } else if let envSocketPath {
            socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            socketPathSource = .implicitDefault
        }
        let cliTelemetry = CLISocketSentryTelemetry(
            command: command,
            commandArgs: commandArgs,
            socketPath: socketPath,
            processEnv: processEnv
        )
        let resolvedSocketPath = CLISocketPathResolver.resolve(
            requestedPath: socketPath,
            source: socketPathSource,
            environment: processEnv
        )

        // If the argument looks like a path (not a known command), open a workspace there.
        if looksLikePath(command) {
            try openPath(command, socketPath: resolvedSocketPath)
            return
        }

        if command == "settings" {
            try runSettings(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "config" {
            try runConfigCommand(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "shortcuts" {
            try runShortcuts(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }
        if command == "open" { try runOpenCommand(commandArgs: commandArgs, socketPath: resolvedSocketPath, explicitPassword: socketPasswordArg, jsonOutput: jsonOutput, idFormat: try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)); return }
        if command == "restore-session" {
            try runRestoreSession(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "themes" {
            try runThemes(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "events" {
            try runEventsCommand(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        let browserAvailabilityArgs = commandArgs.filter { $0 != "--json" }
        if command == "disable-browser" ||
            command == "enable-browser" ||
            command == "browser-status" ||
            (command == "browser" && ["disable", "enable", "status"].contains(browserAvailabilityArgs.first?.lowercased() ?? "")) {
            try runBrowserAvailabilityCommand(
                command: command,
                commandArgs: commandArgs,
                jsonOutput: jsonOutput,
                environment: processEnv
            )
            return
        }

        let client = SocketClient(path: resolvedSocketPath)
        if resolvedSocketPath != socketPath {
            cliTelemetry.breadcrumb(
                "socket.path.autodiscovered",
                data: [
                    "requested_path": socketPath,
                    "resolved_path": resolvedSocketPath
                ]
            )
        }
        cliTelemetry.breadcrumb(
            "socket.connect.attempt",
            data: [
                "command": command,
                "path": resolvedSocketPath
            ]
        )
        do {
            try client.connect()
            cliTelemetry.breadcrumb("socket.connect.success", data: ["path": resolvedSocketPath])
        } catch {
            cliTelemetry.breadcrumb("socket.connect.failure", data: ["path": resolvedSocketPath])
            cliTelemetry.captureError(stage: "socket_connect", error: error)
            throw error
        }
        defer { client.close() }

        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPasswordArg,
            socketPath: resolvedSocketPath
        )

        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)
        // Existing CLI --window routing focuses first so commands without an
        // explicit window_id still target the selected window.
        if let windowId {
            do {
                let normalizedWindow = try normalizeWindowHandle(windowId, client: client) ?? windowId
                _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
            } catch {
                captureSocketTransportError(telemetry: cliTelemetry, stage: "socket_command_window_focus", error: error, client: client)
                throw error
            }
        }

        let capturesSocketErrorsInsideCommand = false
        do {
        switch command {
        case "ping":
            let response = try sendV1Command("ping", client: client)
            print(response)

        case "capabilities":
            let response = try client.sendV2(method: "system.capabilities")
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "auth", "login", "logout":
            let authArgs = command == "auth" ? commandArgs : [command] + commandArgs
            let sub = authArgs.first?.lowercased() ?? "status"
            switch sub {
            case "status":
                let response = try client.sendV2(method: "auth.status")
                if jsonOutput {
                    print(jsonString(response))
                    break
                }
                let signedIn = (response["signed_in"] as? Bool) ?? false
                if !signedIn {
                    print("Not signed in.")
                    print("Run: cmux auth login")
                    break
                }
                let user = response["user"] as? [String: Any]
                let email = user?["email"] as? String
                let display = user?["display_name"] as? String
                let userID = user?["id"] as? String
                print("Signed in.")
                if let email { print("  email:    \(email)") }
                if let display { print("  name:     \(display)") }
                if let userID { print("  user_id:  \(userID)") }
                if let teamID = response["selected_team_id"] as? String {
                    print("  team_id:  \(teamID)")
                }

            case "login":
                let statusBefore = try client.sendV2(method: "auth.status")
                if (statusBefore["signed_in"] as? Bool) == true {
                    let email = (statusBefore["user"] as? [String: Any])?["email"] as? String
                    print("Already signed in\(email.map { " as \($0)" } ?? ""). Use `cmux auth logout` to sign out first.")
                    break
                }
                print("Opening sign-in popup on the cmux web app.")
                // auth.begin_sign_in blocks on the server side until the
                // popup completes (or 5min timeout). The response is the
                // callback — no polling.
                let result = try client.sendV2(method: "auth.begin_sign_in", responseTimeout: 305)
                if (result["signed_in"] as? Bool) == true {
                    let email = (result["user"] as? [String: Any])?["email"] as? String
                    print("Signed in\(email.map { " as \($0)" } ?? "").")
                } else if (result["timed_out"] as? Bool) == true {
                    print("Timed out waiting for sign-in. Run `cmux auth status` once you've finished in the popup.")
                } else {
                    print("Sign-in did not complete. Run `cmux auth status` to check.")
                }

            case "logout":
                let statusBefore = try client.sendV2(method: "auth.status")
                if (statusBefore["signed_in"] as? Bool) != true {
                    print("Already signed out.")
                    break
                }
                // auth.sign_out awaits the token clear before replying.
                let result = try client.sendV2(method: "auth.sign_out")
                if (result["signed_in"] as? Bool) != true {
                    print("Signed out.")
                } else {
                    print("Sign-out requested but state hasn't cleared yet. Run `cmux auth status` to confirm.")
                }

            default:
                throw CLIError(message: "Usage: cmux auth <status|login|logout>")
            }

        case "rpc":
            guard let method = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !method.isEmpty else {
                throw CLIError(message: "Usage: cmux rpc <method> [json-params]")
            }
            let params = try parseRPCParams(Array(commandArgs.dropFirst()))
            let response = try client.sendV2(method: method, params: params)
            let output: Any = idFormatArg == nil ? response : formatIDs(response, mode: idFormat)
            print(jsonString(output))

        case "identify":
            var params: [String: Any] = [:]
            let includeCaller = !hasFlag(commandArgs, name: "--no-caller")
            if includeCaller {
                let idWsFlag = optionValue(commandArgs, name: "--workspace")
                let workspaceArg = idWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
                let surfaceArg = optionValue(commandArgs, name: "--surface") ?? (idWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
                if workspaceArg != nil || surfaceArg != nil {
                    let workspaceId = try normalizeWorkspaceHandle(
                        workspaceArg,
                        client: client,
                        allowCurrent: surfaceArg != nil
                    )
                    var caller: [String: Any] = [:]
                    if let workspaceId {
                        caller["workspace_id"] = workspaceId
                    }
                    if surfaceArg != nil {
                        guard let surfaceId = try normalizeSurfaceHandle(
                            surfaceArg,
                            client: client,
                            workspaceHandle: workspaceId
                        ) else {
                            throw CLIError(message: "Invalid surface handle")
                        }
                        caller["surface_id"] = surfaceId
                    }
                    if !caller.isEmpty {
                        params["caller"] = caller
                    }
                }
            }
            let response = try client.sendV2(method: "system.identify", params: params)
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "list-windows":
            let response = try sendV1Command("list_windows", client: client)
            if jsonOutput {
                let windows = parseWindows(response)
                let payload = windows.map { item -> [String: Any] in
                    var dict: [String: Any] = [
                        "index": item.index,
                        "id": item.id,
                        "key": item.key,
                        "workspace_count": item.workspaceCount,
                    ]
                    dict["selected_workspace_id"] = item.selectedWorkspaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "current-window":
            let response = try sendV1Command("current_window", client: client)
            if jsonOutput {
                print(jsonString(["window_id": response]))
            } else {
                print(response)
            }

        case "new-window":
            let response = try sendV1Command("new_window", client: client)
            print(response)

        case "focus-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "focus-window requires --window")
            }
            let response = try sendV1Command("focus_window \(target)", client: client)
            print(response)

        case "close-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "close-window requires --window")
            }
            let response = try sendV1Command("close_window \(target)", client: client)
            print(response)

        case "move-workspace-to-window":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "move-workspace-to-window requires --workspace")
            }
            guard let windowRaw = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "move-workspace-to-window requires --window")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let payload = try client.sendV2(method: "workspace.move_to_window", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace", "window"]))

        case "move-surface":
            try runMoveSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "split-off":
            try runSplitOff(commandName: "split-off", commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-surface":
            try runReorderSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspace":
            try runReorderWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "workspace-action":
            try runWorkspaceAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)
        case "tab-action":
            try runTabAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)
        case "move-tab-to-new-workspace", "detach-tab":
            try runMoveTabToNewWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)
        case "rename-tab":
            try runRenameTab(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "list-workspaces":
            let payload = try client.sendV2(method: "workspace.list")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                if workspaces.isEmpty {
                    print("No workspaces")
                } else {
                    for ws in workspaces {
                        let selected = (ws["selected"] as? Bool) == true
                        let handle = textHandle(ws, idFormat: idFormat)
                        let title = (ws["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        let titlePart = title.isEmpty ? "" : "  \(title)"
                        print("\(prefix)\(handle)\(titlePart)\(selTag)")
                    }
                }
            }

        case "new-workspace":
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
            let (nameOpt, rem2) = parseOption(rem1, name: "--name")
            let (descriptionOpt, rem3) = parseOption(rem2, name: "--description")
            let (layoutOpt, rem4) = parseOption(rem3, name: "--layout")
            let (windowOpt, rem5) = parseOption(rem4, name: "--window")
            let (focusOpt, remaining) = parseOption(rem5, name: "--focus")
            if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>, --layout <json>, --window <id|ref|index>, --focus <true|false>")
            }
            var params: [String: Any] = [:]
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowOpt ?? windowId)
            if let cwdOpt {
                let resolved = resolvePath(cwdOpt)
                params["cwd"] = resolved
            }
            if let nameOpt {
                params["title"] = nameOpt
            }
            if let descriptionOpt {
                params["description"] = descriptionOpt
            }
            if let layoutOpt {
                guard let layoutData = layoutOpt.data(using: .utf8),
                      let layoutObj = try? JSONSerialization.jsonObject(with: layoutData) as? [String: Any] else {
                    throw CLIError(message: "new-workspace: --layout value must be a valid JSON object")
                }
                params["layout"] = layoutObj
            }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let response = try client.sendV2(method: "workspace.create", params: params)
            let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            print("OK \(wsId)")
            if layoutOpt == nil, let commandText = commandOpt, !wsId.isEmpty {
                let text = unescapeSendText(commandText + "\\n")
                let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
                _ = try client.sendV2(method: "surface.send_text", params: sendParams)
            }

        case "new-split":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let (sfArg, rem2) = parseOption(rem1, name: "--surface")
            let (focusOpt, rem3) = parseOption(rem2, name: "--focus")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = sfArg ?? panelArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let direction = try validatedSplitDirection(rem3.first, commandName: "new-split")
            if let unknown = rem3.dropFirst().first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-split: unknown flag '\(unknown)'")
            }
            var params: [String: Any] = ["direction": direction]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "surface.split", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panes":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let panes = payload["panes"] as? [[String: Any]] ?? []
                if panes.isEmpty {
                    print("No panes")
                } else {
                    for pane in panes {
                        let focused = (pane["focused"] as? Bool) == true
                        let handle = textHandle(pane, idFormat: idFormat)
                        let count = pane["surface_count"] as? Int ?? 0
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                    }
                }
            }

        case "list-pane-surfaces":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let paneRaw = optionValue(commandArgs, name: "--pane")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.surfaces", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces in pane")
                } else {
                    for surface in surfaces {
                        let selected = (surface["selected"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        print("\(prefix)\(handle)  \(title)\(selTag)")
                    }
                }
            }

        case "tree":
            try runTreeCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "top":
            try runTopCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let paneRaw = optionValue(commandArgs, name: "--pane") ?? commandArgs.first else {
                throw CLIError(message: "focus-pane requires --pane <id|ref>")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane", "workspace"]))

        case "new-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let direction = optionValue(commandArgs, name: "--direction") ?? "right"
            let url = optionValue(commandArgs, name: "--url")
            let focusOpt = optionValue(commandArgs, name: "--focus")
            var params: [String: Any] = ["direction": direction]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "pane.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "new-surface":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let paneRaw = optionValue(commandArgs, name: "--pane")
            let url = optionValue(commandArgs, name: "--url")
            let focusOpt = optionValue(commandArgs, name: "--focus")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "surface.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "close-surface":
            let csWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = csWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? (csWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.close", params: params)
            if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId,
               let closedSurfaceId = (payload["surface_id"] as? String) ?? sfId {
                try? tmuxPruneCompatSurfaceState(
                    workspaceId: closedWorkspaceId,
                    surfaceId: closedSurfaceId,
                    client: client
                )
            }
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "drag-surface-to-split":
            try runSplitOff(commandName: "drag-surface-to-split", commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "refresh-surfaces":
            let response = try sendV1Command("refresh_surfaces", client: client)
            print(response)
        case "reload-config":
            if let unexpected = commandArgs.first {
                throw CLIError(message: "reload-config does not accept arguments. Unexpected argument '\(unexpected)'")
            }
            let response = try sendV1Command("reload_config", client: client)
            print(response)

        case "surface-health":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.health", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let inWindow = surface["in_window"]
                        let inWindowStr: String
                        if let b = inWindow as? Bool {
                            inWindowStr = " in_window=\(b)"
                        } else {
                            inWindowStr = ""
                        }
                        print("\(handle)  type=\(sType)\(inWindowStr)")
                    }
                }
            }

        case "debug-terminals":
            let unexpected = commandArgs.filter { $0 != "--" }
            if let extra = unexpected.first {
                throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
            }
            let payload = try client.sendV2(method: "debug.terminals")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print(formatDebugTerminalsPayload(payload, idFormat: idFormat))
            }

        case "list-panels":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let focused = (surface["focused"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                        print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                    }
                }
            }

        case "focus-panel":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "focus-panel requires --panel")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "close-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "close-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.close", params: params)
            if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId {
                try? tmuxPruneCompatWorkspaceState(workspaceId: closedWorkspaceId)
            }
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "select-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "select-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.select", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "rename-workspace", "rename-window":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
            let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "\(command) requires a title")
            }
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let params: [String: Any] = ["title": title, "workspace_id": wsId]
            let payload = try client.sendV2(method: "workspace.rename", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "current-workspace":
            let response = try client.sendV2(method: "workspace.current")
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else {
                let handle = formatHandle(response, kind: "workspace", idFormat: idFormat)
                    ?? (response["workspace_id"] as? String)
                    ?? ""
                print(handle)
            }

        case "read-screen":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let trailing = rem2.filter { $0 != "--scrollback" }
            if !trailing.isEmpty {
                throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
            }

            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "send":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let keyArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-panel requires --panel")
            }
            let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-key-panel requires --panel")
            }
            let skpArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            let key = skpArgs.first ?? ""
            guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "sidebar-state":
            let response = try forwardSidebarMetadataCommand(
                "sidebar_state",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "right-sidebar":
            try forwardRightSidebarCommand(
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )

        case "capture-pane",
             "resize-pane",
             "pipe-pane",
             "wait-for",
             "swap-pane",
             "break-pane",
             "join-pane",
             "last-window",
             "last-pane",
             "next-window",
             "previous-window",
             "find-window",
             "clear-history",
             "set-hook",
             "popup",
             "bind-key",
             "unbind-key",
             "copy-mode",
             "set-buffer",
             "paste-buffer",
             "list-buffers",
             "respawn-pane",
             "display-message":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "help":
            print(usage())

        // Browser commands
        case "browser":
            try runBrowserCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Legacy aliases shimmed onto the v2 browser command surface.
        case "open-browser":
            try runBrowserCommand(commandArgs: ["open"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "navigate":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["navigate"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-back":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["back"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-forward":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["forward"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-reload":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["reload"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-url":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["get-url"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-webview":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["focus-webview"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "is-webview-focused":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["is-webview-focused"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Markdown commands
        case "markdown":
            try runMarkdownCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
        } catch {
            if !capturesSocketErrorsInsideCommand {
                captureSocketTransportError(telemetry: cliTelemetry, stage: "socket_command", error: error, client: client)
            }
            throw error
        }
    }

    func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    private func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    private func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown Commands

    private func runMarkdownCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        // Parse routing flags
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--surface")
        let (directionOpt, argsAfterDirection) = parseOption(argsAfterSurface, name: "--direction")
        let (focusOpt, argsAfterFocus) = parseOption(argsAfterDirection, name: "--focus")
        args = argsAfterFocus

        // Determine subcommand. Explicit "open" is supported, otherwise treat
        // a single positional argument as shorthand path.
        let subArgs: [String]
        if let first = args.first, first.lowercased() == "open" {
            subArgs = Array(args.dropFirst())
        } else if args.count == 1, let first = args.first, !first.hasPrefix("-") {
            subArgs = [first]
        } else {
            // Allow path-like first tokens (e.g. plan.md) with trailing args
            // so we can surface specific trailing-arg/flag errors below.
            if let first = args.first, first.hasPrefix("-") {
                throw CLIError(
                    message:
                        "markdown open: unknown flag '\(first)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up] [--focus <true|false>]"
                )
            } else if let first = args.first, looksLikePath(first) || first.contains(".") {
                subArgs = args
            } else if let first = args.first {
                throw CLIError(message: "Unknown markdown subcommand: \(first). Usage: cmux markdown open <path>")
            } else {
                subArgs = []
            }
        }

        guard let rawPath = subArgs.first, !rawPath.isEmpty else {
            throw CLIError(message: "markdown open requires a file path. Usage: cmux markdown open <path>")
        }
        let trailingArgs = Array(subArgs.dropFirst())
        if let unknownFlag = trailingArgs.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(
                message:
                    "markdown open: unknown flag '\(unknownFlag)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up] [--focus <true|false>]"
            )
        }
        if let extraArg = trailingArgs.first {
            throw CLIError(
                message:
                    "markdown open: unexpected argument '\(extraArg)'. Usage: cmux markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--direction right|down|left|up] [--focus <true|false>]"
            )
        }

        let absolutePath = resolvePath(rawPath)

        // Build params
        let direction = directionOpt ?? "right"
        var params: [String: Any] = ["path": absolutePath, "direction": direction]
        if let surfaceRaw = surfaceOpt {
            if let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = surface
            }
        }
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        if let workspaceRaw {
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
        }
        if let windowRaw = windowOpt {
            if let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
        }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)

        let payload = try client.sendV2(method: "markdown.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let filePath = (payload["path"] as? String) ?? absolutePath
            print("OK surface=\(surfaceText) pane=\(paneText) path=\(filePath)")
        }
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    private func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    /// Open a path in cmux by creating a new workspace with the given directory.
    /// Launches the app if it isn't already running.
    private func openPath(_ path: String, socketPath: String) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            // It's a file; use its parent directory
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        // Try connecting to the socket. If it fails, launch the app and retry.
        let client = SocketClient(path: socketPath)
        if (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            defer { launchedClient.close() }
            let params: [String: Any] = ["cwd": directory]
            let response = try launchedClient.sendV2(method: "workspace.create", params: params)
            let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            if !wsRef.isEmpty {
                print("OK \(wsRef)")
            }
            try activateApp()
            return
        }
        defer { client.close() }

        let params: [String: Any] = ["cwd": directory]
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        // Bring the app to front
        try activateApp()
    }

    private func runRestoreSession(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "restore-session: unknown flag '\(unknown)'")
        }

        let initialClient = SocketClient(path: socketPath)
        let client: SocketClient
        let launched: Bool
        if (try? initialClient.connect()) == nil {
            initialClient.close()
            try launchApp()
            client = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            launched = true
        } else {
            client = initialClient
            launched = false
        }

        defer { client.close() }
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )

        let response = try client.sendV2(method: "session.restore_previous")
        if jsonOutput {
            var payload = response
            payload["launched"] = launched
            print(jsonString(payload))
        } else {
            print("OK")
        }
    }

    func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }
    }

    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
        try process.run()
        process.waitUntilExit()
    }

    private func activateApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
        try process.run()
        process.waitUntilExit()
    }

    private func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    private func sendV1Command(_ command: String, client: SocketClient) throws -> String {
        let response = try client.send(command: command)
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: response)
        }
        return response
    }

    func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
    }

    private func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "window.current")
            return (current["window_ref"] as? String) ?? (current["window_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid window handle: \(trimmed) (expected UUID, ref like window:1, or index)")
        }

        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        for item in windows where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Window index not found")
    }

    func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "workspace.current")
            return (current["workspace_ref"] as? String) ?? (current["workspace_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid workspace handle: \(trimmed) (expected UUID, ref like workspace:1, or index)")
        }

        var params: [String: Any] = [:]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "workspace.list", params: params)
        let items = listed["workspaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Workspace index not found")
    }

    func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["pane_ref"] as? String) ?? (focused["pane_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid pane handle: \(trimmed) (expected UUID, ref like pane:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "pane.list", params: params)
        let items = listed["panes"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Pane index not found")
    }

    func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_ref"] as? String) ?? (focused["surface_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid surface handle: \(trimmed) (expected UUID, ref like surface:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let items = listed["surfaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Surface index not found")
    }

    private func canonicalSurfaceHandleFromTabInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "tab",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    private func normalizeTabHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromTabInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            allowFocused: false
        )
    }

    private func displayTabHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "surface",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "tab:\(ordinal)"
    }

    func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["tab_id"] as? String) ?? (payload["surface_id"] as? String)
        let refRaw = (payload["tab_ref"] as? String) ?? (payload["surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

    private func debugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func debugBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return parseBoolString(string)
        }
        return nil
    }

    private func debugFlag(_ value: Any?) -> String {
        guard let bool = debugBool(value) else { return "nil" }
        return bool ? "1" : "0"
    }

    private func formatDebugRect(_ value: Any?) -> String? {
        guard let rect = value as? [String: Any],
              let x = doubleFromAny(rect["x"]),
              let y = doubleFromAny(rect["y"]),
              let width = doubleFromAny(rect["width"]),
              let height = doubleFromAny(rect["height"]) else {
            return nil
        }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", x, y, width, height)
    }

    private func formatDebugPorts(_ value: Any?) -> String {
        guard let array = value as? [Any], !array.isEmpty else { return "[]" }
        let ports = array
            .compactMap { intFromAny($0) }
            .map(String.init)
        return ports.isEmpty ? "[]" : ports.joined(separator: ",")
    }

    private func formatDebugList(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        let items = array.compactMap { item -> String? in
            if let string = item as? String {
                return string
            }
            return debugString(item)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: ">")
    }

    private func formatDebugAge(_ value: Any?) -> String? {
        guard let seconds = doubleFromAny(value) else { return nil }
        return String(format: "%.3fs", seconds)
    }

    private func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        guard !terminals.isEmpty else { return "No terminal surfaces" }

        return terminals.map { item in
            let index = intFromAny(item["index"]) ?? 0
            let surface = formatHandle(item, kind: "surface", idFormat: idFormat) ?? "?"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "nil"
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "nil"
            let pane = formatHandle(item, kind: "pane", idFormat: idFormat) ?? "nil"
            let bonsplitTab = debugString(item["bonsplit_tab_id"]) ?? "nil"
            let lastKnownWorkspace = debugString(item["last_known_workspace_ref"]) ?? debugString(item["last_known_workspace_id"]) ?? "nil"
            let titleSuffix: String = {
                guard let title = debugString(item["surface_title"]), !title.isEmpty else { return "" }
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return " \"\(escaped)\""
            }()
            let branchLabel: String = {
                guard let branch = debugString(item["git_branch"]), !branch.isEmpty else { return "nil" }
                return debugBool(item["git_dirty"]) == true ? "\(branch)*" : branch
            }()
            let teardownLabel: String = {
                guard debugBool(item["teardown_requested"]) == true else { return "nil" }
                let reason = debugString(item["teardown_requested_reason"]) ?? "requested"
                let age = formatDebugAge(item["teardown_requested_age_seconds"]) ?? "unknown"
                return "\(reason)@\(age)"
            }()
            let portalHostLabel: String = {
                let hostId = debugString(item["portal_host_id"]) ?? "nil"
                let area = doubleFromAny(item["portal_host_area"]).map { String(format: "%.1f", $0) } ?? "nil"
                let inWindow = debugFlag(item["portal_host_in_window"])
                return "\(hostId)/win=\(inWindow)/area=\(area)"
            }()
            let windowMetaLabel: String = {
                let title = debugString(item["window_title"]) ?? "nil"
                let windowClass = debugString(item["window_class"]) ?? "nil"
                let controllerClass = debugString(item["window_controller_class"]) ?? "nil"
                let delegateClass = debugString(item["window_delegate_class"]) ?? "nil"
                return "title=\(title) class=\(windowClass) controller=\(controllerClass) delegate=\(delegateClass)"
            }()

            let line1 =
                "[\(index)] \(surface)\(titleSuffix) " +
                "mapped=\(debugFlag(item["mapped"])) tree=\(debugFlag(item["tree_visible"])) " +
                "window=\(window) workspace=\(workspace) pane=\(pane) bonsplitTab=\(bonsplitTab) " +
                "ctx=\(debugString(item["surface_context"]) ?? "nil")"

            let line2 =
                "    runtime=\(debugFlag(item["runtime_surface_ready"])) " +
                "focused=\(debugFlag(item["surface_focused"])) " +
                "selected=\(debugFlag(item["surface_selected_in_pane"])) " +
                "pinned=\(debugFlag(item["surface_pinned"])) " +
                "terminal=\(debugString(item["terminal_object_ptr"]) ?? "nil") " +
                "hosted=\(debugString(item["hosted_view_ptr"]) ?? "nil") " +
                "ghostty=\(debugString(item["ghostty_surface_ptr"]) ?? "nil") " +
                "portal=\(debugString(item["portal_binding_state"]) ?? "nil")#\(debugString(item["portal_binding_generation"]) ?? "nil") " +
                "teardown=\(teardownLabel)"

            let line3 =
                "    tty=\(debugString(item["tty"]) ?? "nil") " +
                "cwd=\(debugString(item["current_directory"]) ?? debugString(item["requested_working_directory"]) ?? "nil") " +
                "branch=\(branchLabel) " +
                "ports=\(formatDebugPorts(item["listening_ports"])) " +
                "visible=\(debugFlag(item["hosted_view_visible_in_ui"])) " +
                "inWindow=\(debugFlag(item["hosted_view_in_window"])) " +
                "superview=\(debugFlag(item["hosted_view_has_superview"])) " +
                "hidden=\(debugFlag(item["hosted_view_hidden"])) " +
                "ancestorHidden=\(debugFlag(item["hosted_view_hidden_or_ancestor_hidden"])) " +
                "firstResponder=\(debugFlag(item["surface_view_first_responder"])) " +
                "windowNum=\(debugString(item["window_number"]) ?? "nil") " +
                "windowKey=\(debugFlag(item["window_key"])) " +
                "frame=\(formatDebugRect(item["hosted_view_frame_in_window"]) ?? "nil")"

            let line4 =
                "    created=\(formatDebugAge(item["surface_age_seconds"]) ?? "nil") " +
                "runtimeCreated=\(formatDebugAge(item["runtime_surface_age_seconds"]) ?? "nil") " +
                "lastWorkspace=\(lastKnownWorkspace) " +
                "initialCommand=\(debugString(item["initial_command"]) ?? "nil") " +
                "portalHost=\(portalHostLabel)"

            let line5 =
                "    window=\(windowMetaLabel) " +
                "chain=\(formatDebugList(item["hosted_view_superview_chain"]) ?? "nil")"

            return [line1, line2, line3, line4, line5].joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? commandArgs.first
        guard let workspaceRaw else {
            throw CLIError(message: "reorder-workspace requires --workspace <id|ref|index>")
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-workspace")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-workspace")
        let beforeHandle = try normalizeWorkspaceHandle(beforeRaw, client: client, windowHandle: windowHandle)
        let afterHandle = try normalizeWorkspaceHandle(afterRaw, client: client, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_workspace_id"] = beforeHandle }
        if let afterHandle { params["after_workspace_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }

        let payload = try client.sendV2(method: "workspace.reorder", params: params)
        let summary = "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")
        let (colorOpt, rem3) = parseOption(rem2, name: "--color")
        let (descriptionOpt, rem4) = parseOption(rem3, name: "--description")

        var positional = rem4
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)

        let inferredPositionalRaw = positional.joined(separator: " ")
        let inferredPositional = inferredPositionalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (action == "rename" && !inferredPositional.isEmpty ? inferredPositional : nil))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        let color = (
            colorOpt ?? (action == "set_color" ? (inferredPositional.isEmpty ? nil : inferredPositional) : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_color", (color?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-color requires --color <name|#hex> (or a trailing color)")
        }

        let description = (
            descriptionOpt ?? (action == "set_description" && !inferredPositional.isEmpty ? inferredPositionalRaw : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_description", (description?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-description requires --description <text> (or trailing text)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let color, !color.isEmpty {
            params["color"] = color
        }
        if let description, !description.isEmpty {
            params["description"] = description
        }

        let payload = try client.sendV2(method: "workspace.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        if let color = payload["color"] as? String {
            summaryParts.append("color=\(color)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    func runTabAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")
        let (focusOpt, rem6) = parseOption(rem5, name: "--focus")

        var positional = rem6
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "tab-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tab-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let tabArg = tabOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowOverride == nil
                ? (ProcessInfo.processInfo.environment["CMUX_TAB_ID"] ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
                : nil)

        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        let allowFocusedFallback = (workspaceId == nil)
        let surfaceId = try normalizeTabHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "tab-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try applyTabActionFocusOption(focusOpt, to: &params)
        let payload = try client.sendV2(method: "tab.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let tabHandle = formatTabHandle(payload, idFormat: idFormat) { summaryParts.append("tab=\(tabHandle)") }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) { summaryParts.append("workspace=\(workspaceHandle)") }
        if let closed = payload["closed"] { summaryParts.append("closed=\(closed)") }
        if let created = formatCreatedTabHandle(payload, idFormat: idFormat) { summaryParts.append("created=\(created)") }
        appendCreatedWorkspaceSummaryParts(from: payload, idFormat: idFormat, to: &summaryParts)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }
    private func runRenameTab(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")

        if rem3.contains("--action") {
            throw CLIError(message: "rename-tab does not accept --action (it always performs rename)")
        }
        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-tab: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem3
            .dropFirst(rem3.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-tab requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let tabOpt {
            forwarded += ["--tab", tabOpt]
        } else if let surfaceOpt {
            forwarded += ["--surface", surfaceOpt]
        }

        try runTabAction(
            commandArgs: forwarded,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }
    func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func execInteractiveProgram(
        launchPath: String,
        arguments: [String]
    ) throws -> Never {
        var argv = ([launchPath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if launchPath.contains("/") {
            execv(launchPath, &argv)
        } else {
            execvp(launchPath, &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch \(launchPath): \(String(cString: strerror(code)))")
    }

    private func cliDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let trimmedExplicit = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String? = {
            if let trimmedExplicit, !trimmedExplicit.isEmpty {
                return trimmedExplicit
            }
            guard let marker = try? String(contentsOfFile: "/tmp/cmux-last-debug-log-path", encoding: .utf8) else {
                return nil
            }
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMarker.isEmpty ? nil : trimmedMarker
        }()
        guard let path else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [cmux-cli] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
#endif
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            stdinText: stdinText,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }

    private func runBrowserCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard !commandArgs.isEmpty else {
            throw CLIError(message: "browser requires a subcommand")
        }

        var effectiveJSONOutput = jsonOutput
        var effectiveIDFormat = idFormat
        var browserArgs = commandArgs

        // Browser-skill examples often place output flags at the end of the command.
        // Strip trailing display flags so they don't become part of a URL or selector.
        while !browserArgs.isEmpty {
            if browserArgs.last == "--json" {
                effectiveJSONOutput = true
                browserArgs.removeLast()
                continue
            }

            if browserArgs.count >= 2,
               browserArgs[browserArgs.count - 2] == "--id-format" {
                let raw = browserArgs.last!
                guard let parsed = try CLIIDFormat.parse(raw) else {
                    throw CLIError(message: "--id-format must be one of: refs, uuids, both")
                }
                effectiveIDFormat = parsed
                browserArgs.removeLast(2)
                continue
            }

            break
        }

        let (surfaceOpt, argsWithoutSurfaceFlag) = parseOption(browserArgs, name: "--surface")
        var surfaceRaw = surfaceOpt
        var args = argsWithoutSurfaceFlag

        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify", "import", "profile", "profiles"]
        if surfaceRaw == nil, let first = args.first {
            if !first.hasPrefix("-") && !verbsWithoutSurface.contains(first.lowercased()) {
                surfaceRaw = first
                args = Array(args.dropFirst())
            }
        }

        guard let subcommandRaw = args.first else {
            throw CLIError(message: "browser requires a subcommand")
        }
        let subcommand = subcommandRaw.lowercased()
        let subArgs = Array(args.dropFirst())

        func requireSurface() throws -> String {
            guard let raw = surfaceRaw else {
                throw CLIError(message: "browser \(subcommand) requires a surface handle (use: browser <surface> \(subcommand) ... or --surface)")
            }
            guard let resolved = try normalizeSurfaceHandle(raw, client: client) else {
                throw CLIError(message: "Invalid surface handle")
            }
            return resolved
        }

        func output(_ payload: [String: Any], fallback: String) {
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                return
            }
            print(fallback)
            if let snapshot = payload["post_action_snapshot"] as? String,
               !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(snapshot)
            }
        }

        func displaySnapshotText(_ payload: [String: Any]) -> String {
            let snapshotText = (payload["snapshot"] as? String) ?? "Empty page"
            guard snapshotText.contains("\n- (empty)") else {
                return snapshotText
            }

            let url = ((payload["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let readyState = ((payload["ready_state"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = [snapshotText]

            if !url.isEmpty {
                lines.append("url: \(url)")
            }
            if !readyState.isEmpty {
                lines.append("ready_state: \(readyState)")
            }
            if url.isEmpty || url == "about:blank" {
                lines.append("hint: run 'cmux browser <surface> get url' to verify navigation")
            }

            return lines.joined(separator: "\n")
        }

        func displayBrowserValue(_ value: Any) -> String {
            if let dict = value as? [String: Any],
               let type = dict["__cmux_t"] as? String,
               type == "undefined" {
                return "undefined"
            }
            if value is NSNull {
                return "null"
            }
            if let string = value as? String {
                return string
            }
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }

        func displayBrowserLogItems(_ value: Any?) -> String? {
            guard let items = value as? [Any], !items.isEmpty else {
                return nil
            }

            let lines = items.map { item -> String in
                guard let dict = item as? [String: Any] else {
                    return displayBrowserValue(item)
                }

                let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let levelRaw = (dict["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let level = levelRaw.isEmpty ? "log" : levelRaw

                if text.isEmpty {
                    if let message = (dict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !message.isEmpty {
                        return "[error] \(message)"
                    }
                    return displayBrowserValue(dict)
                }
                return "[\(level)] \(text)"
            }

            return lines.joined(separator: "\n")
        }
        func nonFlagArgs(_ values: [String]) -> [String] {
            values.filter { !$0.hasPrefix("-") }
        }

        func optionValues(_ values: [String], names: Set<String>) throws -> [String] {
            var result: [String] = []
            var index = 0
            while index < values.count {
                let value = values[index]
                if names.contains(value) {
                    guard index + 1 < values.count,
                          !values[index + 1].hasPrefix("-"),
                          !names.contains(values[index + 1]) else {
                        throw CLIError(message: "\(value) requires a value")
                    }
                    result.append(values[index + 1])
                    index += 2
                    continue
                }
                index += 1
            }
            return result
        }

        func firstOptionValue(_ values: [String], names: Set<String>) throws -> String? {
            try optionValues(values, names: names).first
        }

        func intPayloadValue(_ value: Any?) -> Int {
            if let intValue = value as? Int { return intValue }
            if let number = value as? NSNumber { return number.intValue }
            return 0
        }

        func stringPayloadValue(_ value: Any?) -> String? {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func browserProfileLine(_ raw: Any) -> String? {
            guard let profile = raw as? [String: Any],
                  let name = stringPayloadValue(profile["name"]),
                  let slug = stringPayloadValue(profile["slug"]),
                  let id = stringPayloadValue(profile["id"]) else {
                return nil
            }
            var markers: [String] = []
            if (profile["current"] as? Bool) == true {
                markers.append("current")
            }
            if (profile["built_in_default"] as? Bool) == true {
                markers.append("default")
            }
            let suffix = markers.isEmpty ? "" : " (\(markers.joined(separator: ", ")))"
            return "\(slug)\t\(name)\t\(id)\(suffix)"
        }

        func printBrowserProfiles(_ payload: [String: Any]) {
            guard let profiles = payload["profiles"] as? [Any], !profiles.isEmpty else {
                print("No browser profiles")
                return
            }
            for profile in profiles {
                if let line = browserProfileLine(profile) {
                    print(line)
                }
            }
        }

        if subcommand == "identify" {
            let surface = try normalizeSurfaceHandle(surfaceRaw, client: client, allowFocused: true)
            var payload = try client.sendV2(method: "system.identify")
            if let surface {
                let urlPayload = try client.sendV2(method: "browser.url.get", params: ["surface_id": surface])
                let titlePayload = try client.sendV2(method: "browser.get.title", params: ["surface_id": surface])
                var browser: [String: Any] = [:]
                browser["surface"] = surface
                browser["url"] = urlPayload["url"] ?? ""
                browser["title"] = titlePayload["title"] ?? ""
                payload["browser"] = browser
            }
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "profile" || subcommand == "profiles" {
            let profileVerb = subArgs.first?.lowercased() ?? "list"
            let profileArgs = subArgs.first != nil ? Array(subArgs.dropFirst()) : []
            let normalizedVerb: String
            switch profileVerb {
            case "ls":
                normalizedVerb = "list"
            case "add", "new":
                normalizedVerb = "create"
            case "remove", "rm":
                normalizedVerb = "delete"
            default:
                normalizedVerb = profileVerb
            }

            switch normalizedVerb {
            case "list":
                let payload = try client.sendV2(method: "browser.profiles.list")
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else {
                    printBrowserProfiles(payload)
                }
            case "create":
                let (nameOpt, remaining) = parseOption(profileArgs, name: "--name")
                let name = nameOpt ?? nonFlagArgs(remaining).joined(separator: " ")
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a name")
                }
                let payload = try client.sendV2(method: "browser.profiles.create", params: ["name": name])
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else if let profileDict = payload["profile"] as? [String: Any],
                          let profile = browserProfileLine(profileDict) {
                    print("Created browser profile \(profile)")
                } else {
                    print("Created browser profile")
                }
            case "rename":
                let (profileOpt, rem1) = parseOption(profileArgs, name: "--profile")
                let (nameOpt, rem2) = parseOption(rem1, name: "--name")
                let positional = nonFlagArgs(rem2)
                let profile = profileOpt ?? positional.first
                let newName = nameOpt ?? (positional.count > 1 ? positional.dropFirst().joined(separator: " ") : nil)
                guard let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a profile")
                }
                guard let newName, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a new name")
                }
                let payload = try client.sendV2(
                    method: "browser.profiles.rename",
                    params: ["profile": profile, "new_name": newName]
                )
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else if let renamed = stringPayloadValue((payload["profile"] as? [String: Any])?["name"]) {
                    print("Renamed browser profile to \(renamed).")
                } else {
                    print("Renamed browser profile.")
                }
            case "clear":
                let (profileOpt, rem1) = parseOption(profileArgs, name: "--profile")
                let positional = nonFlagArgs(rem1)
                var params: [String: Any] = [:]
                if hasFlag(profileArgs, name: "--all") {
                    params["all"] = true
                } else if let profile = profileOpt ?? positional.first {
                    params["profile"] = profile
                } else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a profile or --all")
                }
                if hasFlag(profileArgs, name: "--force") {
                    params["force"] = true
                }
                let payload = try client.sendV2(method: "browser.profiles.clear", params: params, responseTimeout: 120)
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else {
                    let count = intPayloadValue(payload["count"])
                    print("Cleared \(count) browser profile\(count == 1 ? "" : "s").")
                }
            case "delete":
                let (profileOpt, rem1) = parseOption(profileArgs, name: "--profile")
                let profile = profileOpt ?? nonFlagArgs(rem1).first
                guard let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a profile")
                }
                let payload = try client.sendV2(
                    method: "browser.profiles.delete",
                    params: ["profile": profile],
                    responseTimeout: 120
                )
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else if let deleted = stringPayloadValue((payload["profile"] as? [String: Any])?["name"]) {
                    print("Deleted browser profile \(deleted).")
                } else {
                    print("Deleted browser profile.")
                }
            default:
                throw CLIError(message: "Unsupported browser profiles subcommand: \(profileVerb)")
            }
            return
        }

        if subcommand == "import" {
            let importArgs = subArgs
            let importValueOptions: Set<String> = [
                "--from",
                "--browser",
                "--source",
                "--profile",
                "--source-profile",
                "--to",
                "--to-profile",
                "--destination-profile",
                "--domain",
                "--domains",
            ]
            let importFlags: Set<String> = [
                "--interactive",
                "--non-interactive",
                "--noninteractive",
                "--yes",
                "-y",
                "--all-profiles",
                "--create-profile",
                "--create-destination-profile",
            ]
            func importPositionals(_ values: [String]) -> [String] {
                var result: [String] = []
                var index = 0
                var pastTerminator = false
                while index < values.count {
                    let value = values[index]
                    if pastTerminator {
                        result.append(value)
                        index += 1
                        continue
                    }
                    if value == "--" {
                        pastTerminator = true
                        index += 1
                        continue
                    }
                    if importValueOptions.contains(value) {
                        index += index + 1 < values.count ? 2 : 1
                        continue
                    }
                    if importFlags.contains(value) || value.hasPrefix("-") {
                        index += 1
                        continue
                    }
                    result.append(value)
                    index += 1
                }
                return result
            }
            let unsupportedPositionals = importPositionals(importArgs)
            if let first = unsupportedPositionals.first {
                let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized == "cookie" || normalized == "cookies" {
                    throw CLIError(message: "browser import no longer takes a data type; use 'cmux browser import'")
                }
                throw CLIError(message: "browser import does not accept positional arguments")
            }
            let forceInteractive = hasFlag(importArgs, name: "--interactive")
            let forceNonInteractive = hasFlag(importArgs, name: "--non-interactive") ||
                hasFlag(importArgs, name: "--noninteractive") ||
                hasFlag(importArgs, name: "--yes") ||
                hasFlag(importArgs, name: "-y")
            if forceInteractive && forceNonInteractive {
                throw CLIError(message: "browser import cannot use both --interactive and --non-interactive")
            }

            let shouldRunNonInteractive = forceNonInteractive

            var params: [String: Any] = shouldRunNonInteractive ? ["scope": "cookiesOnly"] : [:]
            if let browser = try firstOptionValue(importArgs, names: ["--from", "--browser", "--source"]) {
                params["browser"] = browser
            }
            let sourceProfiles = try optionValues(importArgs, names: ["--profile", "--source-profile"])
            if !sourceProfiles.isEmpty {
                params["source_profiles"] = sourceProfiles
            }
            if let destination = try firstOptionValue(importArgs, names: ["--to", "--to-profile", "--destination-profile"]) {
                params["destination_profile"] = destination
            }
            let domainFilters = try optionValues(importArgs, names: ["--domain", "--domains"])
            if !domainFilters.isEmpty {
                params["domain_filters"] = domainFilters
            }
            if hasFlag(importArgs, name: "--all-profiles") {
                params["all_profiles"] = true
            }
            if hasFlag(importArgs, name: "--create-profile") ||
                hasFlag(importArgs, name: "--create-destination-profile") {
                params["create_destination_profile"] = true
            }

            if shouldRunNonInteractive {
                let payload = try client.sendV2(
                    method: "browser.import.cookies",
                    params: params,
                    responseTimeout: 10 * 60
                )
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                    return
                }

                let browserName = (payload["browser"] as? String) ?? "browser"
                let importedCount = intPayloadValue(payload["imported_cookies"])
                let skippedCount = intPayloadValue(payload["skipped_cookies"])
                print("Imported \(importedCount) cookies from \(browserName).")
                if skippedCount > 0 {
                    print("Skipped \(skippedCount) cookies.")
                }
                if let warnings = payload["warnings"] as? [String], !warnings.isEmpty {
                    for warning in warnings {
                        print("Warning: \(warning)")
                    }
                }
            } else {
                let payload = try client.sendV2(method: "browser.import.dialog", params: params, responseTimeout: 10 * 60)
                output(payload, fallback: "OK")
            }
            return
        }

        if subcommand == "open" || subcommand == "open-split" || subcommand == "new" {
            // Parse routing flags before URL assembly so they never leak into the URL string.
            let (workspaceOpt, argsAfterWorkspace) = parseOption(subArgs, name: "--workspace")
            let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
            let (focusOpt, urlArgs) = parseOption(argsAfterWindow, name: "--focus")
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let respectExternalOpenRules: Bool = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_RESPECT_EXTERNAL_OPEN_RULES"] else {
                    return false
                }
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on":
                    return true
                default:
                    return false
                }
            }()

            if surfaceRaw != nil, subcommand == "open" {
                // Treat `browser <surface> open <url>` as navigate for agent-browser ergonomics.
                let sid = try requireSurface()
                guard !url.isEmpty else {
                    throw CLIError(message: "browser <surface> open requires a URL")
                }
                let payload = try client.sendV2(method: "browser.navigate", params: ["surface_id": sid, "url": url])
                output(payload, fallback: "OK")
                return
            }

            var params: [String: Any] = [:]
            if !url.isEmpty {
                params["url"] = url
            }
            if let sourceSurface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = sourceSurface
            }
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            if let workspaceRaw {
                if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                    params["workspace_id"] = workspace
                }
            }
            if respectExternalOpenRules {
                params["respect_external_open_rules"] = true
            }
            if let windowRaw = windowOpt {
                if let window = try normalizeWindowHandle(windowRaw, client: client) {
                    params["window_id"] = window
                }
            }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "browser.open_split", params: params)
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: effectiveIDFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: effectiveIDFormat) ?? "unknown"
            let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
            output(payload, fallback: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
            return
        }

        if subcommand == "goto" || subcommand == "navigate" {
            let sid = try requireSurface()
            var urlArgs = subArgs
            let snapshotAfter = urlArgs.last == "--snapshot-after"
            if snapshotAfter {
                urlArgs.removeLast()
            }
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires a URL")
            }
            var params: [String: Any] = ["surface_id": sid, "url": url]
            if snapshotAfter {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: "browser.navigate", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "back" || subcommand == "forward" || subcommand == "reload" {
            let sid = try requireSurface()
            let methodMap: [String: String] = [
                "back": "browser.back",
                "forward": "browser.forward",
                "reload": "browser.reload",
            ]
            var params: [String: Any] = ["surface_id": sid]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "url" || subcommand == "get-url" {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print((payload["url"] as? String) ?? "")
            }
            return
        }

        if ["focus-webview", "focus_webview"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.focus_webview", params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if ["is-webview-focused", "is_webview_focused"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.is_webview_focused", params: ["surface_id": sid])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print((payload["focused"] as? Bool) == true ? "true" : "false")
            }
            return
        }

        if subcommand == "snapshot" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (depthOpt, _) = parseOption(rem1, name: "--max-depth")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }
            if hasFlag(subArgs, name: "--interactive") || hasFlag(subArgs, name: "-i") {
                params["interactive"] = true
            }
            if hasFlag(subArgs, name: "--cursor") {
                params["cursor"] = true
            }
            if hasFlag(subArgs, name: "--compact") {
                params["compact"] = true
            }
            if let depthOpt {
                guard let depth = Int(depthOpt), depth >= 0 else {
                    throw CLIError(message: "--max-depth must be a non-negative integer")
                }
                params["max_depth"] = depth
            }

            let payload = try client.sendV2(method: "browser.snapshot", params: params)
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print(displaySnapshotText(payload))
            }
            return
        }

        if subcommand == "eval" {
            let sid = try requireSurface()
            let script = optionValue(subArgs, name: "--script") ?? subArgs.joined(separator: " ")
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIError(message: "browser eval requires a script")
            }
            let payload = try client.sendV2(method: "browser.eval", params: ["surface_id": sid, "script": trimmed])
            let fallback: String
            if let value = payload["value"] {
                fallback = displayBrowserValue(value)
            } else {
                fallback = "OK"
            }
            output(payload, fallback: fallback)
            return
        }

        if subcommand == "wait" {
            let sid = try requireSurface()
            var params: [String: Any] = ["surface_id": sid]

            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let (urlContainsOptA, rem3) = parseOption(rem2, name: "--url-contains")
            let (urlContainsOptB, rem4) = parseOption(rem3, name: "--url")
            let (loadStateOpt, rem5) = parseOption(rem4, name: "--load-state")
            let (functionOpt, rem6) = parseOption(rem5, name: "--function")
            let (timeoutOptMs, rem7) = parseOption(rem6, name: "--timeout-ms")
            let (timeoutOptSec, rem8) = parseOption(rem7, name: "--timeout")

            if let selector = selectorOpt ?? rem8.first {
                params["selector"] = selector
            }
            if let textOpt {
                params["text_contains"] = textOpt
            }
            if let urlContains = urlContainsOptA ?? urlContainsOptB {
                params["url_contains"] = urlContains
            }
            if let loadStateOpt {
                params["load_state"] = loadStateOpt
            }
            if let functionOpt {
                params["function"] = functionOpt
            }
            if let timeoutOptMs {
                guard let ms = Int(timeoutOptMs) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = ms
            } else if let timeoutOptSec {
                guard let seconds = Double(timeoutOptSec) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: "browser.wait", params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["click", "dblclick", "hover", "focus", "check", "uncheck", "scrollintoview", "scrollinto", "scroll-into-view"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }
            let methodMap: [String: String] = [
                "click": "browser.click",
                "dblclick": "browser.dblclick",
                "hover": "browser.hover",
                "focus": "browser.focus",
                "check": "browser.check",
                "uncheck": "browser.uncheck",
                "scrollintoview": "browser.scroll_into_view",
                "scrollinto": "browser.scroll_into_view",
                "scroll-into-view": "browser.scroll_into_view",
            ]
            var params: [String: Any] = ["surface_id": sid, "selector": selector]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["type", "fill"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }

            let positional = selectorOpt != nil ? rem2 : Array(rem2.dropFirst())
            let hasExplicitText = textOpt != nil || !positional.isEmpty
            let text: String
            if let textOpt {
                text = textOpt
            } else {
                text = positional.joined(separator: " ")
            }
            if subcommand == "type" {
                guard hasExplicitText, !text.isEmpty else {
                    throw CLIError(message: "browser type requires text")
                }
            }

            let method = (subcommand == "type") ? "browser.type" : "browser.fill"
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "text": text]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["press", "key", "keydown", "keyup"].contains(subcommand) {
            let sid = try requireSurface()
            let (keyOpt, rem1) = parseOption(subArgs, name: "--key")
            let key = keyOpt ?? rem1.first
            guard let key else {
                throw CLIError(message: "browser \(subcommand) requires a key")
            }
            let methodMap: [String: String] = [
                "press": "browser.press",
                "key": "browser.press",
                "keydown": "browser.keydown",
                "keyup": "browser.keyup",
            ]
            var params: [String: Any] = ["surface_id": sid, "key": key]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "select" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser select requires a selector")
            }
            let value = valueOpt ?? (selectorOpt != nil ? rem2.first : rem2.dropFirst().first)
            guard let value else {
                throw CLIError(message: "browser select requires a value")
            }
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "value": value]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: "browser.select", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "scroll" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (dxOpt, rem2) = parseOption(rem1, name: "--dx")
            let (dyOpt, rem3) = parseOption(rem2, name: "--dy")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }

            if let dxOpt {
                guard let dx = Int(dxOpt) else {
                    throw CLIError(message: "--dx must be an integer")
                }
                params["dx"] = dx
            }
            if let dyOpt {
                guard let dy = Int(dyOpt) else {
                    throw CLIError(message: "--dy must be an integer")
                }
                params["dy"] = dy
            } else if let first = rem3.first, let dy = Int(first) {
                params["dy"] = dy
            }
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }

            let payload = try client.sendV2(method: "browser.scroll", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "screenshot" {
            let sid = try requireSurface()
            let (outPathOpt, _) = parseOption(subArgs, name: "--out")
            let localJSONOutput = hasFlag(subArgs, name: "--json")
            let outputAsJSON = effectiveJSONOutput || localJSONOutput
            var payload = try client.sendV2(method: "browser.screenshot", params: ["surface_id": sid])

            func fileURL(fromPath rawPath: String) -> URL {
                let resolvedPath = resolvePath(rawPath)
                return URL(fileURLWithPath: resolvedPath).standardizedFileURL
            }

            func writeScreenshot(_ data: Data, to destinationURL: URL) throws {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            }

            func hasText(_ value: String?) -> Bool {
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            var screenshotPath = payload["path"] as? String
            var screenshotURL = payload["url"] as? String

            func syncScreenshotLocationFields() {
                if !hasText(screenshotPath),
                   let rawURL = screenshotURL,
                   let fileURL = URL(string: rawURL),
                   fileURL.isFileURL,
                   !fileURL.path.isEmpty {
                    screenshotPath = fileURL.path
                }
                if !hasText(screenshotURL),
                   let screenshotPath,
                   hasText(screenshotPath) {
                    screenshotURL = URL(fileURLWithPath: screenshotPath).standardizedFileURL.absoluteString
                }
                if let screenshotPath, hasText(screenshotPath) {
                    payload["path"] = screenshotPath
                }
                if let screenshotURL, hasText(screenshotURL) {
                    payload["url"] = screenshotURL
                }
            }

            func persistPayloadScreenshot(to destinationURL: URL, allowFailure: Bool) throws -> Bool {
                if let sourcePath = screenshotPath, hasText(sourcePath) {
                    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
                    do {
                        if sourceURL.path != destinationURL.path {
                            try FileManager.default.createDirectory(
                                at: destinationURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try? FileManager.default.removeItem(at: destinationURL)
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        }
                        return true
                    } catch {
                        if payload["png_base64"] == nil {
                            if allowFailure {
                                return false
                            }
                            throw error
                        }
                    }
                }

                if let b64 = payload["png_base64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    do {
                        try writeScreenshot(data, to: destinationURL)
                        return true
                    } catch {
                        if allowFailure {
                            return false
                        }
                        throw error
                    }
                }

                return false
            }

            if let outPathOpt {
                let outputURL = fileURL(fromPath: outPathOpt)
                guard try persistPayloadScreenshot(to: outputURL, allowFailure: false) else {
                    throw CLIError(message: "browser screenshot missing image data")
                }
                screenshotPath = outputURL.path
                screenshotURL = outputURL.absoluteString
                payload["path"] = screenshotPath
                payload["url"] = screenshotURL
            } else {
                syncScreenshotLocationFields()
                if !hasText(screenshotPath) && !hasText(screenshotURL) {
                    let outputDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cmux-browser-screenshots-cli", isDirectory: true)
                    if (try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)) != nil {
                        bestEffortPruneTemporaryFiles(in: outputDir)
                        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                        let safeSid = sanitizedFilenameComponent(sid)
                        let filename = "surface-\(safeSid)-\(timestampMs)-\(String(UUID().uuidString.prefix(8))).png"
                        let outputURL = outputDir.appendingPathComponent(filename, isDirectory: false)
                        if (try? persistPayloadScreenshot(to: outputURL, allowFailure: true)) == true {
                            screenshotPath = outputURL.path
                            screenshotURL = outputURL.absoluteString
                            payload["path"] = screenshotPath
                            payload["url"] = screenshotURL
                        }
                    }
                }
            }

            if outputAsJSON {
                let formattedPayload = formatIDs(payload, mode: effectiveIDFormat)
                if var outputPayload = formattedPayload as? [String: Any] {
                    if hasText(screenshotPath) || hasText(screenshotURL) {
                        outputPayload.removeValue(forKey: "png_base64")
                    }
                    print(jsonString(outputPayload))
                } else {
                    print(jsonString(formattedPayload))
                }
            } else if let outPathOpt {
                print("OK \(outPathOpt)")
            } else if let screenshotURL,
                      hasText(screenshotURL) {
                print("OK \(screenshotURL)")
            } else if let screenshotPath,
                      hasText(screenshotPath) {
                print("OK \(screenshotPath)")
            } else {
                print("OK")
            }
            return
        }

        if subcommand == "get" {
            let sid = try requireSurface()
            guard let getVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser get requires a subcommand")
            }
            let getArgs = Array(subArgs.dropFirst())

            switch getVerb {
            case "url":
                let payload = try client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
                output(payload, fallback: (payload["url"] as? String) ?? "")
            case "title":
                let payload = try client.sendV2(method: "browser.get.title", params: ["surface_id": sid])
                output(payload, fallback: (payload["title"] as? String) ?? "")
            case "text", "html", "value", "count", "box", "styles", "attr":
                let (selectorOpt, rem1) = parseOption(getArgs, name: "--selector")
                let selector = selectorOpt ?? rem1.first
                if getVerb != "title" && getVerb != "url" {
                    guard selector != nil else {
                        throw CLIError(message: "browser get \(getVerb) requires a selector")
                    }
                }
                var params: [String: Any] = ["surface_id": sid]
                if let selector {
                    params["selector"] = selector
                }
                if getVerb == "attr" {
                    let (attrOpt, rem2) = parseOption(rem1, name: "--attr")
                    let attr = attrOpt ?? rem2.dropFirst().first
                    guard let attr else {
                        throw CLIError(message: "browser get attr requires --attr <name>")
                    }
                    params["attr"] = attr
                }
                if getVerb == "styles" {
                    let (propOpt, _) = parseOption(rem1, name: "--property")
                    if let propOpt {
                        params["property"] = propOpt
                    }
                }

                let methodMap: [String: String] = [
                    "text": "browser.get.text",
                    "html": "browser.get.html",
                    "value": "browser.get.value",
                    "attr": "browser.get.attr",
                    "count": "browser.get.count",
                    "box": "browser.get.box",
                    "styles": "browser.get.styles",
                ]
                let payload = try client.sendV2(method: methodMap[getVerb]!, params: params)
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else if let value = payload["value"] {
                    if let str = value as? String {
                        print(str)
                    } else {
                        print(jsonString(value))
                    }
                } else if let count = payload["count"] {
                    print("\(count)")
                } else {
                    print("OK")
                }
            default:
                throw CLIError(message: "Unsupported browser get subcommand: \(getVerb)")
            }
            return
        }

        if subcommand == "is" {
            let sid = try requireSurface()
            guard let isVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser is requires a subcommand")
            }
            let isArgs = Array(subArgs.dropFirst())
            let (selectorOpt, rem1) = parseOption(isArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser is \(isVerb) requires a selector")
            }

            let methodMap: [String: String] = [
                "visible": "browser.is.visible",
                "enabled": "browser.is.enabled",
                "checked": "browser.is.checked",
            ]
            guard let method = methodMap[isVerb] else {
                throw CLIError(message: "Unsupported browser is subcommand: \(isVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "selector": selector])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else if let value = payload["value"] {
                print("\(value)")
            } else {
                print("false")
            }
            return
        }


        if subcommand == "find" {
            let sid = try requireSurface()
            guard let locator = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser find requires a locator (role|text|label|placeholder|alt|title|testid|first|last|nth)")
            }
            let locatorArgs = Array(subArgs.dropFirst())

            var params: [String: Any] = ["surface_id": sid]
            let method: String

            switch locator {
            case "role":
                let (nameOpt, rem1) = parseOption(locatorArgs, name: "--name")
                let candidates = nonFlagArgs(rem1)
                guard let role = candidates.first else {
                    throw CLIError(message: "browser find role requires <role>")
                }
                params["role"] = role
                if let nameOpt {
                    params["name"] = nameOpt
                }
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = "browser.find.role"
            case "text", "label", "placeholder", "alt", "title", "testid":
                let keyMap: [String: String] = [
                    "text": "text",
                    "label": "label",
                    "placeholder": "placeholder",
                    "alt": "alt",
                    "title": "title",
                    "testid": "testid",
                ]
                let candidates = nonFlagArgs(locatorArgs)
                guard let value = candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a value")
                }
                params[keyMap[locator]!] = value
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = "browser.find.\(locator)"
            case "first", "last":
                let (selectorOpt, rem1) = parseOption(locatorArgs, name: "--selector")
                let candidates = nonFlagArgs(rem1)
                guard let selector = selectorOpt ?? candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a selector")
                }
                params["selector"] = selector
                method = "browser.find.\(locator)"
            case "nth":
                let (indexOpt, rem1) = parseOption(locatorArgs, name: "--index")
                let (selectorOpt, rem2) = parseOption(rem1, name: "--selector")
                let candidates = nonFlagArgs(rem2)
                let indexRaw = indexOpt ?? candidates.first
                guard let indexRaw,
                      let index = Int(indexRaw) else {
                    throw CLIError(message: "browser find nth requires an integer index")
                }
                let selector = selectorOpt ?? (candidates.count >= 2 ? candidates[1] : nil)
                guard let selector else {
                    throw CLIError(message: "browser find nth requires a selector")
                }
                params["index"] = index
                params["selector"] = selector
                method = "browser.find.nth"
            default:
                throw CLIError(message: "Unsupported browser find locator: \(locator)")
            }

            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "frame" {
            let sid = try requireSurface()
            guard let frameVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser frame requires <selector|main>")
            }
            if frameVerb == "main" {
                let payload = try client.sendV2(method: "browser.frame.main", params: ["surface_id": sid])
                output(payload, fallback: "OK")
                return
            }
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser frame requires a selector or 'main'")
            }
            let payload = try client.sendV2(method: "browser.frame.select", params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "dialog" {
            let sid = try requireSurface()
            guard let dialogVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser dialog requires <accept|dismiss> [text]")
            }
            let remainder = Array(subArgs.dropFirst())
            switch dialogVerb {
            case "accept":
                let text = remainder.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var params: [String: Any] = ["surface_id": sid]
                if !text.isEmpty {
                    params["text"] = text
                }
                let payload = try client.sendV2(method: "browser.dialog.accept", params: params)
                output(payload, fallback: "OK")
            case "dismiss":
                let payload = try client.sendV2(method: "browser.dialog.dismiss", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser dialog subcommand: \(dialogVerb)")
            }
            return
        }

        if subcommand == "download" {
            let sid = try requireSurface()
            let argsForDownload: [String]
            if subArgs.first?.lowercased() == "wait" {
                argsForDownload = Array(subArgs.dropFirst())
            } else {
                argsForDownload = subArgs
            }

            let (pathOpt, rem1) = parseOption(argsForDownload, name: "--path")
            let (timeoutMsOpt, rem2) = parseOption(rem1, name: "--timeout-ms")
            let (timeoutSecOpt, rem3) = parseOption(rem2, name: "--timeout")

            var params: [String: Any] = ["surface_id": sid]
            if let path = pathOpt ?? nonFlagArgs(rem3).first {
                params["path"] = path
            }
            if let timeoutMsOpt {
                guard let timeoutMs = Int(timeoutMsOpt) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = timeoutMs
            } else if let timeoutSecOpt {
                guard let seconds = Double(timeoutSecOpt) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: "browser.download.wait", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "cookies" {
            let sid = try requireSurface()
            let cookieVerb = subArgs.first?.lowercased() ?? "get"
            let cookieArgs = subArgs.first != nil ? Array(subArgs.dropFirst()) : []

            let (nameOpt, rem1) = parseOption(cookieArgs, name: "--name")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let (urlOpt, rem3) = parseOption(rem2, name: "--url")
            let (domainOpt, rem4) = parseOption(rem3, name: "--domain")
            let (pathOpt, rem5) = parseOption(rem4, name: "--path")
            let (expiresOpt, _) = parseOption(rem5, name: "--expires")

            var params: [String: Any] = ["surface_id": sid]
            if let nameOpt { params["name"] = nameOpt }
            if let valueOpt { params["value"] = valueOpt }
            if let urlOpt { params["url"] = urlOpt }
            if let domainOpt { params["domain"] = domainOpt }
            if let pathOpt { params["path"] = pathOpt }
            if hasFlag(cookieArgs, name: "--secure") {
                params["secure"] = true
            }
            if hasFlag(cookieArgs, name: "--all") {
                params["all"] = true
            }
            if let expiresOpt {
                guard let expires = Int(expiresOpt) else {
                    throw CLIError(message: "--expires must be an integer Unix timestamp")
                }
                params["expires"] = expires
            }

            switch cookieVerb {
            case "get":
                let payload = try client.sendV2(method: "browser.cookies.get", params: params)
                output(payload, fallback: "OK")
            case "set":
                var setParams = params
                let positional = nonFlagArgs(cookieArgs)
                if setParams["name"] == nil, positional.count >= 1 {
                    setParams["name"] = positional[0]
                }
                if setParams["value"] == nil, positional.count >= 2 {
                    setParams["value"] = positional[1]
                }
                guard setParams["name"] != nil, setParams["value"] != nil else {
                    throw CLIError(message: "browser cookies set requires <name> <value> (or --name/--value)")
                }
                let payload = try client.sendV2(method: "browser.cookies.set", params: setParams)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: "browser.cookies.clear", params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser cookies subcommand: \(cookieVerb)")
            }
            return
        }

        if subcommand == "storage" {
            let sid = try requireSurface()
            let storageArgs = subArgs
            let storageType = storageArgs.first?.lowercased() ?? "local"
            guard storageType == "local" || storageType == "session" else {
                throw CLIError(message: "browser storage requires type: local|session")
            }
            let op = storageArgs.count >= 2 ? storageArgs[1].lowercased() : "get"
            let rest = storageArgs.count > 2 ? Array(storageArgs.dropFirst(2)) : []
            let positional = nonFlagArgs(rest)

            var params: [String: Any] = ["surface_id": sid, "type": storageType]
            switch op {
            case "get":
                if let key = positional.first {
                    params["key"] = key
                }
                let payload = try client.sendV2(method: "browser.storage.get", params: params)
                output(payload, fallback: "OK")
            case "set":
                guard positional.count >= 2 else {
                    throw CLIError(message: "browser storage \(storageType) set requires <key> <value>")
                }
                params["key"] = positional[0]
                params["value"] = positional[1]
                let payload = try client.sendV2(method: "browser.storage.set", params: params)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: "browser.storage.clear", params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser storage subcommand: \(op)")
            }
            return
        }

        if subcommand == "tab" {
            let sid = try requireSurface()
            let first = subArgs.first?.lowercased()
            let tabVerb: String
            let tabArgs: [String]
            if let first, ["new", "list", "close", "switch"].contains(first) {
                tabVerb = first
                tabArgs = Array(subArgs.dropFirst())
            } else if let first, Int(first) != nil {
                tabVerb = "switch"
                tabArgs = subArgs
            } else {
                tabVerb = "list"
                tabArgs = subArgs
            }

            switch tabVerb {
            case "list":
                let payload = try client.sendV2(method: "browser.tab.list", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            case "new":
                var params: [String: Any] = ["surface_id": sid]
                let url = tabArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    params["url"] = url
                }
                let payload = try client.sendV2(method: "browser.tab.new", params: params)
                output(payload, fallback: "OK")
            case "switch", "close":
                let method = (tabVerb == "switch") ? "browser.tab.switch" : "browser.tab.close"
                var params: [String: Any] = ["surface_id": sid]
                let target = tabArgs.first
                if let target {
                    if let index = Int(target) {
                        params["index"] = index
                    } else {
                        params["target_surface_id"] = target
                    }
                }
                let payload = try client.sendV2(method: method, params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser tab subcommand: \(tabVerb)")
            }
            return
        }

        if subcommand == "console" {
            let sid = try requireSurface()
            let consoleVerb = subArgs.first?.lowercased() ?? "list"
            let method = (consoleVerb == "clear") ? "browser.console.clear" : "browser.console.list"
            if consoleVerb != "list" && consoleVerb != "clear" {
                throw CLIError(message: "Unsupported browser console subcommand: \(consoleVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            if effectiveJSONOutput || consoleVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["entries"]) ?? "No console entries")
            }
            return
        }

        if subcommand == "errors" {
            let sid = try requireSurface()
            let errorsVerb = subArgs.first?.lowercased() ?? "list"
            var params: [String: Any] = ["surface_id": sid]
            if errorsVerb == "clear" {
                params["clear"] = true
            } else if errorsVerb != "list" {
                throw CLIError(message: "Unsupported browser errors subcommand: \(errorsVerb)")
            }
            let payload = try client.sendV2(method: "browser.errors.list", params: params)
            if effectiveJSONOutput || errorsVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["errors"]) ?? "No browser errors")
            }
            return
        }

        if subcommand == "highlight" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser highlight requires a selector")
            }
            let payload = try client.sendV2(method: "browser.highlight", params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "state" {
            let sid = try requireSurface()
            guard let stateVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser state requires save|load <path>")
            }
            guard subArgs.count >= 2 else {
                throw CLIError(message: "browser state \(stateVerb) requires a file path")
            }
            let path = subArgs[1]
            let method: String
            switch stateVerb {
            case "save":
                method = "browser.state.save"
            case "load":
                method = "browser.state.load"
            default:
                throw CLIError(message: "Unsupported browser state subcommand: \(stateVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "path": path])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "addinitscript" || subcommand == "addscript" || subcommand == "addstyle" {
            let sid = try requireSurface()
            let field = (subcommand == "addstyle") ? "css" : "script"
            let flag = (subcommand == "addstyle") ? "--css" : "--script"
            let (scriptOpt, rem1) = parseOption(subArgs, name: flag)
            let content = (scriptOpt ?? rem1.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires content")
            }
            let payload = try client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid, field: content])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "viewport" {
            let sid = try requireSurface()
            guard subArgs.count >= 2,
                  let width = Int(subArgs[0]),
                  let height = Int(subArgs[1]) else {
                throw CLIError(message: "browser viewport requires: <width> <height>")
            }
            let payload = try client.sendV2(method: "browser.viewport.set", params: ["surface_id": sid, "width": width, "height": height])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "geolocation" || subcommand == "geo" {
            let sid = try requireSurface()
            guard subArgs.count >= 2,
                  let latitude = Double(subArgs[0]),
                  let longitude = Double(subArgs[1]) else {
                throw CLIError(message: "browser geolocation requires: <latitude> <longitude>")
            }
            let payload = try client.sendV2(method: "browser.geolocation.set", params: ["surface_id": sid, "latitude": latitude, "longitude": longitude])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "offline" {
            let sid = try requireSurface()
            guard let raw = subArgs.first,
                  let enabled = parseBoolString(raw) else {
                throw CLIError(message: "browser offline requires true|false")
            }
            let payload = try client.sendV2(method: "browser.offline.set", params: ["surface_id": sid, "enabled": enabled])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "trace" {
            let sid = try requireSurface()
            guard let traceVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser trace requires start|stop")
            }
            let method: String
            switch traceVerb {
            case "start":
                method = "browser.trace.start"
            case "stop":
                method = "browser.trace.stop"
            default:
                throw CLIError(message: "Unsupported browser trace subcommand: \(traceVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if subArgs.count >= 2 {
                params["path"] = subArgs[1]
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "network" {
            let sid = try requireSurface()
            guard let networkVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser network requires route|unroute|requests")
            }
            let networkArgs = Array(subArgs.dropFirst())
            switch networkVerb {
            case "route":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network route requires a URL/pattern")
                }
                var params: [String: Any] = ["surface_id": sid, "url": pattern]
                if hasFlag(networkArgs, name: "--abort") {
                    params["abort"] = true
                }
                let (bodyOpt, _) = parseOption(networkArgs, name: "--body")
                if let bodyOpt {
                    params["body"] = bodyOpt
                }
                let payload = try client.sendV2(method: "browser.network.route", params: params)
                output(payload, fallback: "OK")
            case "unroute":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network unroute requires a URL/pattern")
                }
                let payload = try client.sendV2(method: "browser.network.unroute", params: ["surface_id": sid, "url": pattern])
                output(payload, fallback: "OK")
            case "requests":
                let payload = try client.sendV2(method: "browser.network.requests", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser network subcommand: \(networkVerb)")
            }
            return
        }

        if subcommand == "screencast" {
            let sid = try requireSurface()
            guard let castVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser screencast requires start|stop")
            }
            let method: String
            switch castVerb {
            case "start":
                method = "browser.screencast.start"
            case "stop":
                method = "browser.screencast.stop"
            default:
                throw CLIError(message: "Unsupported browser screencast subcommand: \(castVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "input" {
            let sid = try requireSurface()
            guard let inputVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser input requires mouse|keyboard|touch")
            }
            let remainder = Array(subArgs.dropFirst())
            let method: String
            switch inputVerb {
            case "mouse":
                method = "browser.input_mouse"
            case "keyboard":
                method = "browser.input_keyboard"
            case "touch":
                method = "browser.input_touch"
            default:
                throw CLIError(message: "Unsupported browser input subcommand: \(inputVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if !remainder.isEmpty {
                params["args"] = remainder
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["input_mouse", "input_keyboard", "input_touch"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        throw CLIError(message: "Unsupported browser subcommand: \(subcommand)")
    }

    private func parseWindows(_ response: String) -> [WindowInfo] {
        guard response != "No windows" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let key = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = parts[1]

                var selectedWorkspaceId: String?
                var workspaceCount: Int = 0
                for token in parts.dropFirst(2) {
                    if token.hasPrefix("selected_workspace=") {
                        let v = token.replacingOccurrences(of: "selected_workspace=", with: "")
                        selectedWorkspaceId = (v == "none") ? nil : v
                    } else if token.hasPrefix("workspaces=") {
                        let v = token.replacingOccurrences(of: "workspaces=", with: "")
                        workspaceCount = Int(v) ?? 0
                    }
                }

                return WindowInfo(
                    index: index,
                    id: id,
                    key: key,
                    selectedWorkspaceId: selectedWorkspaceId,
                    workspaceCount: workspaceCount
                )
            }
    }

    private func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            // Resolve ref to UUID — search across all windows
            let windows = try client.sendV2(method: "window.list")
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "Workspace ref not found: \(raw)")
        }

        if let raw, let index = Int(raw) {
            let listed = try client.sendV2(method: "workspace.list")
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Workspace index not found")
        }

        let current = try client.sendV2(method: "workspace.current")
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    private func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface ref not found: \(raw)")
        }

        let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let items = listed["surfaces"] as? [[String: Any]] ?? []

        if let raw, let index = Int(raw) {
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface index not found")
        }

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve surface ID")
    }

    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    private func subcommandUsage(_ command: String) -> String? {
        switch command {
        case "ping":
            return """
            Usage: cmux ping

            Check connectivity to the cmux socket server.
            """
        case "capabilities":
            return """
            Usage: cmux capabilities

            Print server capabilities as JSON.
            """
        case "events":
            return """
            Usage: cmux events [options]

            Stream cmux events as newline-delimited JSON.

            Options:
              --after <seq>          Replay retained events after this sequence
              --cursor-file <path>   Read the starting sequence from a file and update it after each event
              --name <event>         Filter by event name, repeatable
              --category <name>      Filter by category, repeatable
              --reconnect            Reconnect forever and resume from the last received sequence
              --limit <n>            Exit after printing n event frames
              --no-ack               Do not print the subscription ack frame
              --no-heartbeat         Do not print heartbeat frames

            Examples:
              cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect
              cmux events --after 42 --category workspace
            """
        case "auth":
            return """
            Usage: cmux auth <status|login|logout>

            status   Print whether the user is signed in (add `cmux --json` for JSON).
            login    Open the sign-in popup on the cmux web app and wait for it to finish.
            logout   Clear the current session.
            """
        case "login":
            return """
            Usage: cmux login

            Alias for `cmux auth login`.
            """
        case "logout":
            return """
            Usage: cmux logout

            Alias for `cmux auth logout`.
            """
        case "rpc":
            return """
            Usage: cmux rpc <method> [json-params]

            Call a raw v2 method with an optional JSON object for params.
            Example: cmux rpc surface.report_tty '{"workspace_id":"...","surface_id":"...","tty_name":"ttys001"}'
            """
        case "help":
            return """
            Usage: cmux help

            Show top-level CLI usage and command list.
            Also works without a running cmux app or socket.
            """
        case "docs":
            return docsUsage()
        case "settings":
            return settingsUsage()
        case "config":
            return configUsage()
        case "welcome":
            return """
            Usage: cmux welcome

            Show a welcome screen with the cmux logo and useful shortcuts.
            Auto-runs once on first launch.
            """
        case "shortcuts":
            return """
            Usage: cmux shortcuts

            Open the Settings window to Keyboard Shortcuts.
            """
        case "disable-browser":
            return """
            Usage: cmux disable-browser [--json]

            Disable cmux browser creation and link interception. This overrides
            browser settings from cmux.json until re-enabled.
            """
        case "enable-browser":
            return """
            Usage: cmux enable-browser [--json]

            Re-enable cmux browser creation and link interception.
            """
        case "browser-status":
            return """
            Usage: cmux browser-status [--json]

            Print whether cmux browser creation and link interception are enabled.
            """
        case "restore-session":
            return """
            Usage: cmux restore-session

            Reopen the previous saved cmux session.

            If the app is already running, this restores the last saved session into the current app.
            If the app is not running, this launches cmux and lets startup restore reopen the saved session.
            """
        case "themes":
            return """
            Usage: cmux themes
                   cmux themes list
                   cmux themes set <theme>
                   cmux themes set --light <theme> [--dark <theme>]
                   cmux themes set --dark <theme> [--light <theme>]
                   cmux themes clear

            When run in a TTY, `cmux themes` opens an interactive theme picker with
            live app preview. Use `cmux themes list` for a plain listing.

            The picker previews the selected theme across the running cmux app and
            lets you apply it to the light theme, dark theme, or both defaults.

            Commands:
              list                      List available themes and mark the current light/dark defaults
              set <theme>               Set the same theme for both light and dark appearance
              set --light <theme>       Set the light appearance theme
              set --dark <theme>        Set the dark appearance theme
              clear                     Remove the cmux theme override and fall back to other config

            Examples:
              cmux themes
              cmux themes list
              cmux themes set "Catppuccin Mocha"
              cmux themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              cmux themes clear
            """
        case "identify":
            return """
            Usage: cmux identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]

            Print server identity and caller context details.

            Flags:
              --workspace <id|ref|index>   Caller workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Caller surface context (default: $CMUX_SURFACE_ID)
              --no-caller                  Omit caller context from the request
            """
        case "list-windows":
            return """
            Usage: cmux list-windows

            List open windows.
            """
        case "current-window":
            return """
            Usage: cmux current-window

            Print the currently selected window ID.
            """
        case "new-window":
            return """
            Usage: cmux new-window

            Create a new window.

            Example:
              cmux new-window
            """
        case "focus-window":
            return """
            Usage: cmux focus-window --window <id|ref|index>

            Focus (bring to front) the specified window.

            Flags:
              --window <id|ref|index>   Window to focus (required)

            Example:
              cmux focus-window --window 0
              cmux focus-window --window window:1
            """
        case "close-window":
            return """
            Usage: cmux close-window --window <id|ref|index>

            Close the specified window.

            Flags:
              --window <id|ref|index>   Window to close (required)

            Example:
              cmux close-window --window 0
              cmux close-window --window window:1
            """
        case "move-workspace-to-window":
            return """
            Usage: cmux move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>

            Move a workspace to a different window.

            Flags:
              --workspace <id|ref|index>   Workspace to move (required)
              --window <id|ref|index>      Target window (required)

            Example:
              cmux move-workspace-to-window --workspace workspace:2 --window window:1
            """
        case "move-surface":
            return """
            Usage: cmux move-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Move a surface to a different pane, workspace, or window.

            Flags:
              --surface <id|ref|index>   Surface to move (required unless passed positionally)
              --pane <id|ref|index>      Target pane
              --workspace <id|ref|index> Target workspace
              --window <id|ref|index>    Target window
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after moving

            Example:
              cmux move-surface --surface surface:1 --workspace workspace:2
              cmux move-surface surface:1 --pane pane:2 --index 0
            """
        case "reorder-surface":
            return """
            Usage: cmux reorder-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Reorder a surface within its pane.

            Flags:
              --surface <id|ref|index>   Surface to reorder (required unless passed positionally)
              --workspace <id|ref|index> Workspace context
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after reordering

            Example:
              cmux reorder-surface --surface surface:1 --index 0
              cmux reorder-surface --surface surface:3 --after surface:1
            """
        case "reorder-workspace":
            return """
            Usage: cmux reorder-workspace [--workspace <id|ref|index> | <id|ref|index>] [flags]

            Reorder a workspace within its window.

            Flags:
              --workspace <id|ref|index>   Workspace to reorder (required unless passed positionally)
              --index <n>                  Place at this index
              --before <id|ref|index>      Place before this workspace
              --before-workspace <id|ref|index>
                                         Alias for --before
              --after <id|ref|index>       Place after this workspace
              --after-workspace <id|ref|index>
                                         Alias for --after
              --window <id|ref|index>      Window context

            Example:
              cmux reorder-workspace --workspace workspace:2 --index 0
              cmux reorder-workspace --workspace workspace:3 --after workspace:1
            """
        case "workspace-action":
            return """
            Usage: cmux workspace-action --action <name> [flags]

            Perform workspace context-menu actions from CLI/socket.

            Actions:
              pin | unpin
              rename | clear-name
              set-description | clear-description
              move-up | move-down | move-top
              close-others | close-above | close-below
              mark-read | mark-unread
              set-color | clear-color

            Flags:
              --action <name>              Action name (required if not positional)
              --workspace <id|ref|index>   Target workspace (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename
              --color <name|#hex>          Color for set-color (name or #RRGGBB hex)
              --description <text>         Description for set-description

            Named colors:
              Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua,
              Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal

            Example:
              cmux workspace-action --workspace workspace:2 --action pin
              cmux workspace-action --action rename --title "infra"
              cmux workspace-action close-others
              cmux workspace-action --action set-color --color blue
              cmux workspace-action --action set-color --color "#C0392B"
              cmux workspace-action set-color Amber
              cmux workspace-action --action set-description --description "Ship checklist"
              cmux workspace-action --action set-description $'Ship checklist\n- verify build\n- post notes'
              cmux workspace-action clear-color
            """
        case "tab-action":
            return """
            Usage: cmux tab-action --action <name> [flags]

            Perform horizontal tab context-menu actions from CLI/socket.

            Actions:
              rename | clear-name
              close-left | close-right | close-others
              new-terminal-right | new-browser-right
              move-to-new-workspace
              reload | duplicate
              pin | unpin
              mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
              --surface <id|ref|index>     Alias for --tab (backward compatibility)
              --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename (or pass trailing title text)
              --url <url>                  Optional URL for new-browser-right
              --focus <true|false>         Focus the destination when supported (default: false for move-to-new-workspace)

            Example:
              cmux tab-action --tab tab:3 --action pin
              cmux tab-action --action close-right
              cmux tab-action --tab tab:2 --action move-to-new-workspace
              cmux tab-action --tab tab:2 --action rename --title "build logs"
            """
        case "move-tab-to-new-workspace", "detach-tab":
            return Self.moveTabToNewWorkspaceCommandHelp
        case "rename-tab":
            return """
            Usage: cmux rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

            Compatibility alias for tab-action rename.

            Resolution order for target tab:
            1) --tab
            2) --surface
            3) $CMUX_TAB_ID / $CMUX_SURFACE_ID
            4) currently focused tab (optionally within --workspace)

            Flags:
              --workspace <id|ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
              --surface <id|ref>     Alias for --tab
              --title <text>         Explicit title (or use trailing positional title)

            Examples:
              cmux rename-tab "build logs"
              cmux rename-tab --tab tab:3 "staging server"
              cmux rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
            """
        case "new-workspace":
            return """
            Usage: cmux new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>] [--window <id|ref|index>] [--focus <true|false>]

            Create a new workspace in the caller's window.

            Flags:
              --name <title>       Set a custom name for the new workspace
              --description <text> Set a custom description for the new workspace
              --cwd <path>         Set the working directory for the new workspace
              --command <text>     Send text+Enter to the new workspace after creation
              --layout <json>      Create workspace with a predefined split layout (inline JSON).
                                   Uses the same schema as cmux.json layout definitions.
                                   When provided, --command is ignored (layout surfaces define their own commands).
              --window <id|ref|index>
                                   Target window (default: caller's window from $CMUX_WORKSPACE_ID/$CMUX_SURFACE_ID)
              --focus <true|false> Focus the new workspace (default: false)

            Example:
              cmux new-workspace
              cmux new-workspace --name "Build Server"
              cmux new-workspace --name "Launch" --description "Ship checklist"
              cmux new-workspace --cwd ~/projects/myapp
              cmux new-workspace --cwd . --command "npm test"
              cmux new-workspace --name "Dev" --layout '{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","command":"vim"}]}},{"pane":{"surfaces":[{"type":"terminal","command":"npm run start"}]}}]}'
            """
        case "list-workspaces":
            return """
            Usage: cmux list-workspaces

            List workspaces in the current window.

            Example:
              cmux list-workspaces
            """
        case "new-split":
            return """
            Usage: cmux new-split <left|right|up|down> [flags]

            Split the current pane in the given direction.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface to split from (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --focus <true|false>   Focus the new split (default: false)

            Example:
              cmux new-split right
              cmux new-split down --workspace workspace:1
            """
        case "list-panes":
            return """
            Usage: cmux list-panes [--workspace <id|ref>]

            List panes in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-panes
              cmux list-panes --workspace workspace:2
            """
        case "list-pane-surfaces":
            return """
            Usage: cmux list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

            List surfaces in a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Restrict to a specific pane (default: focused pane)

            Example:
              cmux list-pane-surfaces
              cmux list-pane-surfaces --workspace workspace:2 --pane pane:1
            """
        case "tree":
            return """
            Usage: cmux tree [flags]

            Print the hierarchy of windows, workspaces, panes, and surfaces.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref|index>   Show only one workspace
              --json                        Structured JSON output

            Output:
              Text mode prints a box-drawing tree with markers:
              - ◀ active (true focused window/workspace/pane/surface path)
              - ◀ here (caller surface where `cmux tree` was invoked)
              - workspace [selected]
              - pane [focused]
              - surface [selected]
              Browser surfaces also include their current URL.

            Example:
              cmux tree
              cmux tree --all
              cmux tree --workspace workspace:2
              cmux --json tree --all
            """
        case "top":
            return """
            Usage: cmux top [flags]

            Print CPU and RAM usage by cmux window, workspace, pane, surface, status tag, and browser webview.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref|index>   Show only one workspace
              --processes                  Include process trees under surfaces, webviews, and tags
              --sort <cpu|rss|proc>         Sort sibling rows by CPU, memory, or process count
              --flat                        Print independent rows for shell sorting
              --format <tree|tsv>           Text output format (tsv implies --flat)
              --json                        Structured JSON output

            Output:
              CPU comes from macOS process accounting and can exceed 100% across cores.
              RSS is summed across the unique process IDs attributed to each tree node.
              Browser webviews are attributed through their WebKit content process PID.
              TSV columns are: cpu_percent, rss_bytes, process_count, kind, ref, parent_ref, title.

            Example:
              cmux top
              cmux top --all
              cmux top --sort cpu
              cmux top --format tsv | sort -t $'\\t' -nrk1,1
              cmux top --workspace workspace:2 --processes
              cmux --json top --all
            """
        case "focus-pane":
            return """
            Usage: cmux focus-pane [--pane <id|ref> | <id|ref>] [flags]

            Focus the specified pane.

            Flags:
              --pane <id|ref>          Pane to focus (required unless passed positionally)
              --workspace <id|ref>     Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux focus-pane --pane pane:2
              cmux focus-pane pane:1
              cmux focus-pane --pane pane:1 --workspace workspace:2
            """
        case "new-pane":
            return """
            Usage: cmux new-pane [flags]

            Create a new pane in the workspace.

            Flags:
              --type <terminal|browser>           Pane type (default: terminal)
              --direction <left|right|up|down>    Split direction (default: right)
              --workspace <id|ref>                Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                         URL for browser panes
              --focus <true|false>                Focus the new pane (default: false)

            Example:
              cmux new-pane
              cmux new-pane --type browser --direction down --url https://example.com
            """
        case "new-surface":
            return """
            Usage: cmux new-surface [flags]

            Create a new surface (tab) in a pane.

            Flags:
              --type <terminal|browser>   Surface type (default: terminal)
              --pane <id|ref>             Target pane
              --workspace <id|ref>        Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                 URL for browser surfaces
              --focus <true|false>        Focus the new surface (default: false)

            Example:
              cmux new-surface
              cmux new-surface --type browser --pane pane:1 --url https://example.com
            """
        case "close-surface":
            return """
            Usage: cmux close-surface [flags]

            Close a surface. Defaults to the focused surface if none specified.

            Flags:
              --surface <id|ref>     Surface to close (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux close-surface
              cmux close-surface --surface surface:3
            """
        case "drag-surface-to-split":
            return """
            Usage: cmux drag-surface-to-split --surface <id|ref|index> <left|right|up|down> [flags]

            Drag a surface into a new split in the given direction.

            Flags:
              --surface <id|ref|index>     Surface to drag (required)
              --panel <id|ref|index>       Alias for --surface
              --workspace <id|ref|index>   Workspace context for ref/index resolution
              --focus <true|false>   Focus the split-off surface (default: false)

            Example:
              cmux drag-surface-to-split --surface surface:1 right
              cmux drag-surface-to-split --panel surface:2 down
            """
        case "split-off":
            return """
            Usage: cmux split-off --surface <id|ref|index> <left|right|up|down> [flags]

            Move an existing surface into a new split without changing focus by default.

            Flags:
              --surface <id|ref|index>     Surface to move (required)
              --panel <id|ref|index>       Alias for --surface
              --workspace <id|ref|index>   Workspace context for ref/index resolution
              --focus <true|false>   Focus the split-off surface (default: false)

            Example:
              cmux split-off --surface surface:1 right
              cmux split-off --workspace workspace:2 --surface surface:4 down
            """
        case "refresh-surfaces":
            return """
            Usage: cmux refresh-surfaces

            Refresh surface snapshots for the focused workspace.
            """
        case "reload-config":
            return """
            Usage: cmux reload-config

            Run the same configuration reload as the Reload Configuration shortcut.
            This reloads Ghostty config, re-reads ~/.config/cmux/cmux.json, and refreshes terminals.

            Example:
              cmux reload-config
            """
        case "surface-health":
            return """
            Usage: cmux surface-health [--workspace <id|ref>]

            List health details for surfaces in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux surface-health
              cmux surface-health --workspace workspace:2
            """
        case "debug-terminals":
            return """
            Usage: cmux debug-terminals

            Print live Ghostty terminal runtime metadata across all windows and workspaces.
            Intended for debugging stray or detached terminal views.
            """
        case "list-panels":
            return """
            Usage: cmux list-panels [--workspace <id|ref>]

            List surfaces (panels) in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-panels
              cmux list-panels --workspace workspace:2
            """
        case "focus-panel":
            return """
            Usage: cmux focus-panel --panel <id|ref> [--workspace <id|ref>]

            Focus a specific panel (surface).

            Flags:
              --panel <id|ref>       Panel/surface to focus (required)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux focus-panel --panel surface:2
              cmux focus-panel --panel surface:5 --workspace workspace:2
            """
        case "close-workspace":
            return """
            Usage: cmux close-workspace --workspace <id|ref|index>

            Close the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to close (required)

            Example:
              cmux close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: cmux select-workspace --workspace <id|ref|index>

            Select (switch to) the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to select (required)

            Example:
              cmux select-workspace --workspace workspace:2
              cmux select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: cmux rename-workspace [--workspace <id|ref|index>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref|index>   Workspace to rename (default: current/$CMUX_WORKSPACE_ID)

            Example:
              cmux rename-workspace "backend logs"
              cmux rename-window --workspace workspace:2 "agent run"
            """
        case "current-workspace":
            return """
            Usage: cmux current-workspace

            Print the currently selected workspace ID.
            """
        case "capture-pane":
            return """
            Usage: cmux capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              cmux capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: cmux resize-pane [--pane <id|ref>] [--workspace <id|ref>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref>        Pane to resize (default: focused pane)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: cmux pipe-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <command>    Shell command to run (or pass as trailing text)
            """
        case "wait-for":
            return """
            Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.

            Flags:
              -S, --signal           Signal the token instead of waiting
              --timeout <seconds>    Wait timeout (default: 30)
            """
        case "swap-pane":
            return """
            Usage: cmux swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>] [--focus <true|false>]

            Swap two panes.

            Flags:
              --pane <id|ref>         Source pane (required)
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --focus <true|false>    Focus the target pane after swapping (default: false)
            """
        case "break-pane":
            return """
            Usage: cmux break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Source pane
              --surface <id|ref>     Source surface
              --focus <true|false>   Focus the result (default: false)
              --no-focus             Compatibility alias for --focus false
            """
        case "join-pane":
            return """
            Usage: cmux join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>         Source pane
              --surface <id|ref>      Source surface
              --focus <true|false>    Focus the result (default: false)
              --no-focus              Compatibility alias for --focus false
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: cmux \(command)

            Switch workspace selection (next/previous/last) in the current window.
            """
        case "last-pane":
            return """
            Usage: cmux last-pane [--workspace <id|ref>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
            """
        case "find-window":
            return """
            Usage: cmux find-window [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --content   Search terminal content in addition to workspace titles
              --select    Select the first match
            """
        case "clear-history":
            return """
            Usage: cmux clear-history [--workspace <id|ref>] [--surface <id|ref>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
            """
        case "set-hook":
            return """
            Usage: cmux set-hook [--list] [--unset <event>] | <event> <command>

            Manage tmux-compat hook definitions.

            Flags:
              --list            List configured hooks
              --unset <event>   Remove a hook by event name
            """
        case "popup":
            return """
            Usage: cmux popup

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "bind-key", "unbind-key", "copy-mode":
            return """
            Usage: cmux \(command)

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "set-buffer":
            return """
            Usage: cmux set-buffer [--name <name>] [--] <text>

            Save text into a named tmux-compat buffer.

            Flags:
              --name <name>   Buffer name (default: default)
            """
        case "paste-buffer":
            return """
            Usage: cmux paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>    Surface context (default: focused surface)
            """
        case "list-buffers":
            return """
            Usage: cmux list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: cmux respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <cmd>        Command text (or pass trailing command text)
            """
        case "display-message":
            return """
            Usage: cmux display-message [-p|--print] <text>

            Print text.

            Flags:
              -p, --print   Print to stdout only
            """
        case "read-screen":
            return """
            Usage: cmux read-screen [flags]

            Read terminal text from a surface as plain text.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback (not just visible viewport)
              --lines <n>            Limit to the last n lines (implies --scrollback)

            Example:
              cmux read-screen
              cmux read-screen --surface surface:2 --scrollback --lines 200
            """
        case "send":
            return """
            Usage: cmux send [flags] [--] <text>

            Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux send "echo hello"
              cmux send --surface surface:2 "ls -la\\n"
            """
        case "send-key":
            return """
            Usage: cmux send-key [flags] [--] <key>

            Send a key event to a terminal surface.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux send-key enter
              cmux send-key --surface surface:2 ctrl+c
            """
        case "send-panel":
            return """
            Usage: cmux send-panel --panel <id|ref> [flags] [--] <text>

            Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux send-panel --panel surface:2 "echo hello\\n"
            """
        case "send-key-panel":
            return """
            Usage: cmux send-key-panel --panel <id|ref> [flags] [--] <key>

            Send a key event to a specific panel (surface).

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux send-key-panel --panel surface:2 enter
              cmux send-key-panel --panel surface:2 ctrl+c
            """
        case "sidebar-state":
            return """
            Usage: cmux sidebar-state [flags]

            Dump all sidebar metadata for a workspace (cwd, git branch, ports,
            status entries, progress, log entries).

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux sidebar-state
              cmux sidebar-state --workspace workspace:2
            """
        case "right-sidebar":
            return String(localized: "cli.rightSidebar.usage", defaultValue: """
            Usage: cmux right-sidebar <command> [flags]

            Control the right sidebar from the CLI.

            Commands:
              toggle                         Toggle right sidebar visibility
              show                           Show the right sidebar
              hide                           Hide the right sidebar
              focus                          Focus the current right sidebar mode
              set <files|find|dock>
                                             Show, switch mode, and focus
              mode                           Print {"visible":bool,"mode":string}
              files|find|dock
                                             Alias for show + set + focus

            Flags:
              --workspace <id|ref|index>     Target the window containing a workspace
              --window <id|ref|index>        Target a window
              --no-focus                     With set, switch mode without moving focus

            Examples:
              cmux right-sidebar toggle
              cmux right-sidebar set find
              cmux right-sidebar set files --no-focus
              cmux right-sidebar mode
            """)
        case "browser":
            return """
            Usage: cmux browser [--surface <id|ref|index> | <surface>] <subcommand> [args]

            Browser automation commands. Most subcommands require a surface handle.
            A surface can be passed as `--surface <handle>` or as the first positional token.
            `open`/`open-split`/`new`/`identify` can run without an explicit surface.

            Subcommands:
              open|open-split|new [url] [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
                open/open-split/new default to $CMUX_WORKSPACE_ID when --workspace is omitted and --window is not set
                --focus defaults to false
              disable | enable | status
              goto|navigate <url> [--snapshot-after]
              back|forward|reload [--snapshot-after]
              url|get-url
              focus-webview | is-webview-focused
              snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval [--script <js> | <js>]
              wait [--selector <css>] [--text <text>] [--url-contains <text>|--url <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>|--timeout <seconds>]
              click|dblclick|hover|focus|check|uncheck|scroll-into-view [--selector <css> | <css>] [--snapshot-after]
              type|fill [--selector <css> | <css>] [--text <text> | <text>] [--snapshot-after]
              press|key|keydown|keyup [--key <key> | <key>] [--snapshot-after]
              select [--selector <css> | <css>] [--value <value> | <value>] [--snapshot-after]
              scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
              screenshot [--out <path>]
              get <url|title|text|html|value|attr|count|box|styles> [...]
                text|html|value|count|box|styles|attr: [--selector <css> | <css>]
                attr: [--attr <name> | <name>]
                styles: [--property <name>]
              is <visible|enabled|checked> [--selector <css> | <css>]
              find <role|text|label|placeholder|alt|title|testid|first|last|nth> [...]
                role: [--name <text>] [--exact] <role>
                text|label|placeholder|alt|title|testid: [--exact] <text>
                first|last: [--selector <css> | <css>]
                nth: [--index <n> | <n>] [--selector <css> | <css>]
              frame <main|selector> [--selector <css>]
              dialog <accept|dismiss> [text]
              download [wait] [--path <path>] [--timeout-ms <ms>|--timeout <seconds>]
              profiles <list|add|rename|clear|delete> [...]
              import [--interactive|--non-interactive|-y|--yes] [--from <browser>] [--profile <name>] [--all-profiles] [--to-profile <name|uuid>] [--create-profile] [--domain <domain>]
              cookies <get|set|clear> [--name <name>] [--value <value>] [--url <url>] [--domain <domain>] [--path <path>] [--expires <unix>] [--secure] [--all]
              storage <local|session> <get|set|clear> [...]
              tab <new|list|switch|close|<index>> [...]
              console <list|clear>
              errors <list|clear>
              highlight [--selector <css> | <css>]
              state <save|load> <path>
              addinitscript|addscript [--script <js> | <js>]
              addstyle [--css <css> | <css>]
              viewport <width> <height>
              geolocation|geo <latitude> <longitude>
              offline <true|false>
              trace <start|stop> [path]
              network <route|unroute|requests> ...
                route <pattern> [--abort] [--body <text>]
                unroute <pattern>
              screencast <start|stop>
              input <mouse|keyboard|touch> [args...]
              input_mouse | input_keyboard | input_touch
              identify [--surface <id|ref|index>]

            Example:
              cmux browser open https://example.com
              cmux browser surface:1 navigate https://google.com
              cmux browser --surface surface:1 snapshot --interactive
            """
        // Legacy browser aliases — point users to `cmux browser --help`
        case "open-browser":
            return "Legacy alias for 'cmux browser open'. Run 'cmux browser --help' for details."
        case "navigate":
            return "Legacy alias for 'cmux browser navigate'. Run 'cmux browser --help' for details."
        case "browser-back":
            return "Legacy alias for 'cmux browser back'. Run 'cmux browser --help' for details."
        case "browser-forward":
            return "Legacy alias for 'cmux browser forward'. Run 'cmux browser --help' for details."
        case "browser-reload":
            return "Legacy alias for 'cmux browser reload'. Run 'cmux browser --help' for details."
        case "get-url":
            return "Legacy alias for 'cmux browser get-url'. Run 'cmux browser --help' for details."
        case "focus-webview":
            return "Legacy alias for 'cmux browser focus-webview'. Run 'cmux browser --help' for details."
        case "is-webview-focused":
            return "Legacy alias for 'cmux browser is-webview-focused'. Run 'cmux browser --help' for details."
        case "open": return openSubcommandUsage()
        case "markdown":
            return """
            Usage: cmux markdown open <path> [options]
                   cmux markdown <path>       (shorthand for 'open')

            Open a markdown file in a formatted viewer panel with live file watching.
            The file is rendered with rich formatting (headings, code blocks, tables,
            lists, blockquotes) and automatically updates when the file changes on disk.

            Options:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Source surface to split from (default: focused surface)
              --window <id|ref|index>      Target window
              --direction <left|right|up|down>  Split direction (default: right)
              --focus <true|false>         Focus the markdown panel (default: false)

            Examples:
              cmux markdown open plan.md
              cmux markdown ~/project/CHANGELOG.md
              cmux markdown open ./docs/design.md --workspace 0
              cmux markdown open plan.md --direction down
            """
        default:
            return nil
        }
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    private func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("cmux \(command)")
        print("")
        print(text)
        return true
    }

    /// Escape and quote a string for safe embedding in a v1 socket command.
    /// The socket tokenizer treats `\` and `"` as special inside quoted strings,
    /// so both must be escaped before wrapping in double quotes. Newlines and
    /// carriage returns must also be escaped since the socket protocol uses
    /// newline as the message terminator.
    private func socketQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                value = args[idx + 1]
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (value, remaining)
    }

    private func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    func optionValue(_ args: [String], name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }

    private func replaceToken(_ args: [String], from: String, to: String) -> [String] {
        args.map { $0 == from ? to : $0 }
    }

    /// Unescape CLI escape sequences to match legacy v1 send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    private func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil { return nil }
        return ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
    }

    private func applyWindowOrCallerContext(to params: inout [String: Any], client: SocketClient, windowRaw: String?) throws {
        if let windowHandle = try normalizeWindowHandle(windowRaw, client: client) {
            params["window_id"] = windowHandle
            return
        }

        let env = ProcessInfo.processInfo.environment
        let workspaceHandle = try normalizeWorkspaceHandle(env["CMUX_WORKSPACE_ID"], client: client)
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let surfaceHandle = try normalizeSurfaceHandle(env["CMUX_SURFACE_ID"], client: client, workspaceHandle: workspaceHandle)
        if let surfaceHandle {
            params["surface_id"] = surfaceHandle
        }
    }

    private func forwardSidebarMetadataCommand(
        _ socketCommand: String,
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String {
        func insertArgumentBeforeSeparator(_ value: String, into args: inout [String]) {
            if let separatorIndex = args.firstIndex(of: "--") {
                args.insert(value, at: separatorIndex)
            } else {
                args.append(value)
            }
        }

        var forwardedArgs: [String] = []
        var resolvedExplicitWorkspace = false
        var index = 0

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--workspace", index + 1 < commandArgs.count {
                let workspaceId = try resolveWorkspaceId(commandArgs[index + 1], client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 2
                continue
            }
            if arg.hasPrefix("--workspace=") {
                let rawWorkspace = String(arg.dropFirst("--workspace=".count))
                let workspaceId = try resolveWorkspaceId(rawWorkspace, client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 1
                continue
            }
            forwardedArgs.append(arg)
            index += 1
        }

        if !resolvedExplicitWorkspace,
           let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride) {
            let workspaceId = try resolveWorkspaceId(workspaceArg, client: client)
            insertArgumentBeforeSeparator("--tab=\(workspaceId)", into: &forwardedArgs)
        }

        let command = ([socketCommand] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        return try sendV1Command(command, client: client)
    }

    private struct RightSidebarCLIArguments {
        let positional: [String]
        let workspace: String?
        let window: String?
        let noFocus: Bool
    }

    private func forwardRightSidebarCommand(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws {
        let parsed = try parseRightSidebarCLIArguments(commandArgs)
        let socketArgs = try rightSidebarSocketArguments(from: parsed)
        let windowId = try resolveRightSidebarWindowId(parsed.window ?? windowOverride, client: client)
        let workspaceId = try resolveRightSidebarWorkspaceId(parsed.workspace, windowId: windowId, client: client)

        var forwardedArgs = socketArgs
        if let workspaceId {
            forwardedArgs.append("--tab=\(workspaceId)")
        }
        if let windowId {
            forwardedArgs.append("--window=\(windowId)")
        }

        let command = (["right_sidebar"] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        let response = try sendV1Command(command, client: client)
        if parsed.positional.first?.lowercased() == "mode" {
            print(response)
        }
    }

    private func parseRightSidebarCLIArguments(_ args: [String]) throws -> RightSidebarCLIArguments {
        var positional: [String] = []
        var workspace: String?
        var window: String?
        var noFocus = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--workspace":
                guard index + 1 < args.count else {
                    throw CLIError(message: String(localized: "cli.rightSidebar.error.workspaceRequiresValue", defaultValue: "right-sidebar: --workspace requires an id"))
                }
                workspace = args[index + 1]
                index += 2
            case "--window":
                guard index + 1 < args.count else {
                    throw CLIError(message: String(localized: "cli.rightSidebar.error.windowRequiresValue", defaultValue: "right-sidebar: --window requires an id"))
                }
                window = args[index + 1]
                index += 2
            case "--no-focus":
                noFocus = true
                index += 1
            default:
                if arg.hasPrefix("--workspace=") {
                    workspace = String(arg.dropFirst("--workspace=".count))
                    index += 1
                } else if arg.hasPrefix("--window=") {
                    window = String(arg.dropFirst("--window=".count))
                    index += 1
                } else if arg.hasPrefix("--") {
                    throw CLIError(message: String(localized: "cli.rightSidebar.error.unknownFlag", defaultValue: "right-sidebar: unknown flag '\(arg)'"))
                } else {
                    positional.append(arg)
                    index += 1
                }
            }
        }

        return RightSidebarCLIArguments(
            positional: positional,
            workspace: workspace,
            window: window,
            noFocus: noFocus
        )
    }

    private func rightSidebarSocketArguments(from parsed: RightSidebarCLIArguments) throws -> [String] {
        guard let action = parsed.positional.first?.lowercased() else {
            throw CLIError(message: String(localized: "cli.rightSidebar.error.missingCommand", defaultValue: "right-sidebar requires a subcommand"))
        }

        switch action {
        case "toggle", "show", "hide", "focus", "mode":
            guard parsed.positional.count == 1 else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.unexpectedArguments", defaultValue: "right-sidebar \(action) received unexpected arguments"))
            }
            guard !parsed.noFocus else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.noFocusOnlySet", defaultValue: "right-sidebar: --no-focus is only valid with set"))
            }
            return [action]

        case "set":
            guard parsed.positional.count == 2 else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.setRequiresMode", defaultValue: "right-sidebar set requires a mode: files, find, or dock"))
            }
            let mode = parsed.positional[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isRightSidebarCLIMode(mode) else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.unknownMode", defaultValue: "Unknown right-sidebar mode '\(parsed.positional[1])'"))
            }
            var args = ["set", mode]
            if parsed.noFocus {
                args.append("--no-focus")
            }
            return args

        case "files", "find", "dock":
            guard parsed.positional.count == 1 else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.unexpectedArguments", defaultValue: "right-sidebar \(action) received unexpected arguments"))
            }
            guard !parsed.noFocus else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.noFocusOnlySet", defaultValue: "right-sidebar: --no-focus is only valid with set"))
            }
            return ["set", action]

        default:
            throw CLIError(message: String(localized: "cli.rightSidebar.error.unknownCommand", defaultValue: "Unknown right-sidebar command '\(action)'"))
        }
    }

    private func isRightSidebarCLIMode(_ value: String) -> Bool {
        switch value {
        case "files", "find", "dock":
            return true
        default:
            return false
        }
    }

    private func resolveRightSidebarWindowId(_ raw: String?, client: SocketClient) throws -> String? {
        guard let normalized = try normalizeWindowHandle(raw, client: client) else { return nil }
        return try resolvedRightSidebarHandleID(
            normalized,
            expectedRefKind: "window",
            invalidMessage: String(localized: "cli.rightSidebar.error.invalidWindow", defaultValue: "Invalid window handle: \(normalized)"),
            missingRefMessage: String(localized: "cli.rightSidebar.error.windowRefNotFound", defaultValue: "Window ref not found"),
            listMethod: "window.list",
            listKey: "windows",
            client: client
        )
    }

    private func resolveRightSidebarWorkspaceId(
        _ raw: String?,
        windowId: String?,
        client: SocketClient
    ) throws -> String? {
        var params: [String: Any] = [:]
        if let windowId {
            params["window_id"] = windowId
        }
        guard let normalized = try normalizeWorkspaceHandle(raw, client: client, windowHandle: windowId) else { return nil }
        return try resolvedRightSidebarHandleID(
            normalized,
            expectedRefKind: "workspace",
            invalidMessage: String(localized: "cli.rightSidebar.error.invalidWorkspace", defaultValue: "Invalid workspace handle: \(normalized)"),
            missingRefMessage: String(localized: "cli.rightSidebar.error.workspaceRefNotFound", defaultValue: "Workspace ref not found"),
            listMethod: "workspace.list",
            listKey: "workspaces",
            listParams: params,
            client: client
        )
    }

    private func resolvedRightSidebarHandleID(
        _ handle: String,
        expectedRefKind: String,
        invalidMessage: String,
        missingRefMessage: String,
        listMethod: String,
        listKey: String,
        listParams: [String: Any] = [:],
        client: SocketClient
    ) throws -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUUID(trimmed) { return trimmed }
        let refIndex: Int?
        if isHandleRef(trimmed) {
            let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0].lowercased() == expectedRefKind else {
                throw CLIError(message: invalidMessage)
            }
            refIndex = Int(pieces[1])
        } else {
            refIndex = nil
        }

        let listed = try client.sendV2(method: listMethod, params: listParams)
        let items = listed[listKey] as? [[String: Any]] ?? []
        for item in items {
            guard let id = item["id"] as? String else { continue }
            if id == trimmed ||
                (item["ref"] as? String) == trimmed ||
                (refIndex != nil && intFromAny(item["index"]) == refIndex) {
                return id
            }
        }
        throw CLIError(message: missingRefMessage)
    }

    /// Pick the display handle for an item dict based on --id-format.
    private func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["surface", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        return parts.joined(separator: " ")
    }

    private struct TreeCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let jsonOutput: Bool
    }

    private struct TopCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let jsonOutput: Bool
        let showProcesses: Bool
        let sortKey: TopSortKey?
        let textFormat: TopTextFormat
        let requestedFlatOutput: Bool
        let requestedFormat: Bool
    }

    private struct TreePath {
        let windowHandle: String?
        let workspaceHandle: String?
        let paneHandle: String?
        let surfaceHandle: String?
    }

    private func runTreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTreeCommandOptions(commandArgs)
        let payload = try buildTreePayload(options: options, client: client)
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let windows = payload["windows"] as? [[String: Any]] ?? []
            print(renderTreeText(windows: windows, idFormat: idFormat))
        }
    }

    private func parseTreeCommandOptions(_ args: [String]) throws -> TreeCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "tree requires --workspace <id|ref|index>")
        }

        var includeAll = false
        var jsonOutput = false
        var remaining: [String] = []
        for arg in rem0 {
            if arg == "--all" {
                includeAll = true
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tree: unknown flag '\(unknown)'. Known flags: --all --workspace <id|ref|index> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "tree: unexpected argument '\(extra)'")
        }

        return TreeCommandOptions(includeAllWindows: includeAll, workspaceHandle: workspaceOpt, jsonOutput: jsonOutput)
    }

    private func runTopCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTopCommandOptions(commandArgs)
        let structuredOutput = jsonOutput || options.jsonOutput
        if structuredOutput, options.sortKey != nil {
            throw CLIError(message: "top: --sort is only supported for text output; use --json to sort structured data externally")
        }
        if structuredOutput, options.requestedFlatOutput || options.requestedFormat {
            throw CLIError(message: "top: --flat and --format are only supported for text output")
        }
        let payload = try buildTopPayload(options: options, client: client)
        if structuredOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            switch options.textFormat {
            case .tree:
                print(renderTopText(
                    payload: payload,
                    idFormat: idFormat,
                    showProcesses: options.showProcesses,
                    sortKey: options.sortKey
                ))
            case .tsv:
                print(renderTopFlatTSV(
                    payload: payload,
                    idFormat: idFormat,
                    showProcesses: options.showProcesses,
                    sortKey: options.sortKey
                ))
            }
        }
    }

    private func parseTopCommandOptions(_ args: [String]) throws -> TopCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "top requires --workspace <id|ref|index>")
        }
        let (sortOpt, rem1) = parseOption(rem0, name: "--sort")
        if rem1.contains("--sort") {
            throw CLIError(message: "top requires --sort <cpu|rss|proc>")
        }
        let (formatOpt, rem2) = parseOption(rem1, name: "--format")
        if rem2.contains("--format") {
            throw CLIError(message: "top requires --format <tree|tsv>")
        }

        var includeAll = false
        var jsonOutput = false
        var showProcesses = false
        var flatOutput = false
        var remaining: [String] = []
        for arg in rem2 {
            if arg == "--all" {
                includeAll = true
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            if arg == "--processes" {
                showProcesses = true
                continue
            }
            if arg == "--flat" {
                flatOutput = true
                continue
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "top: unknown flag '\(unknown)'. Known flags: --all --workspace <id|ref|index> --processes --sort <cpu|rss|proc> --flat --format <tree|tsv> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "top: unexpected argument '\(extra)'")
        }
        let format = try parseTopTextFormat(formatOpt)
        if flatOutput, format == .tree {
            throw CLIError(message: "top: --flat requires --format tsv or no --format")
        }

        return TopCommandOptions(
            includeAllWindows: includeAll,
            workspaceHandle: workspaceOpt,
            jsonOutput: jsonOutput,
            showProcesses: showProcesses,
            sortKey: try parseTopSortKey(sortOpt),
            textFormat: format ?? (flatOutput ? .tsv : .tree),
            requestedFlatOutput: flatOutput,
            requestedFormat: formatOpt != nil
        )
    }

    private func parseTopSortKey(_ raw: String?) throws -> TopSortKey? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "cpu", "cpu%":
            return .cpu
        case "rss", "mem", "memory", "ram":
            return .rss
        case "proc", "process", "processes", "count":
            return .proc
        default:
            throw CLIError(message: "top: invalid --sort value '\(raw)'. Use cpu, rss, or proc")
        }
    }

    private func parseTopTextFormat(_ raw: String?) throws -> TopTextFormat? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "tree":
            return .tree
        case "tsv", "tab", "tabs":
            return .tsv
        default:
            throw CLIError(message: "top: invalid --format value '\(raw)'. Use tree or tsv")
        }
    }

    private func buildTopPayload(
        options: TopCommandOptions,
        client: SocketClient,
        responseTimeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "all_windows": options.includeAllWindows,
            "include_processes": options.showProcesses
        ]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            return try client.sendV2(method: "system.top", params: params, responseTimeout: responseTimeout)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            throw CLIError(message: "cmux top requires a running cmux build with system.top support")
        }
    }

    private func buildTreePayload(
        options: TreeCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = ["all_windows": options.includeAllWindows]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            let payload = try client.sendV2(method: "system.tree", params: params)
            return treePayloadWithMarkers(payload)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            // Back-compat fallback for older servers that don't support system.tree.
            return try buildLegacyTreePayload(options: options, params: params, client: client)
        }
    }

    private func buildLegacyTreePayload(
        options: TreeCommandOptions,
        params: [String: Any],
        client: SocketClient
    ) throws -> [String: Any] {
        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }

        let identifyPayload = try client.sendV2(method: "system.identify", params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: focused)
        let windows = try buildTreeWindowNodes(options: options, activePath: activePath, client: client)

        return treePayloadWithMarkers([
            "active": focused.isEmpty ? NSNull() : focused,
            "caller": caller.isEmpty ? NSNull() : caller,
            "windows": windows
        ])
    }

    private func buildTreeWindowNodes(
        options: TreeCommandOptions,
        activePath: TreePath,
        client: SocketClient
    ) throws -> [[String: Any]] {
        let windowsPayload = try client.sendV2(method: "window.list")
        let allWindows = windowsPayload["windows"] as? [[String: Any]] ?? []

        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }

            let workspaceListPayload = try client.sendV2(method: "workspace.list", params: ["workspace_id": workspaceHandle])
            let workspaceWindowHandle = (workspaceListPayload["window_ref"] as? String) ?? (workspaceListPayload["window_id"] as? String)
            let window = allWindows.first(where: { treeItemMatchesHandle($0, handle: workspaceWindowHandle) })
                ?? treeFallbackWindow(from: workspaceListPayload)

            let workspaces = workspaceListPayload["workspaces"] as? [[String: Any]] ?? []
            if workspaces.isEmpty {
                throw CLIError(message: "Workspace not found")
            }
            let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
            var node = window
            let isActiveWindow = treeItemMatchesHandle(node, handle: activePath.windowHandle)
            node["current"] = isActiveWindow
            node["active"] = isActiveWindow
            node["workspaces"] = workspaceNodes
            node["workspace_count"] = workspaceNodes.count
            return [node]
        }

        let targetWindows: [[String: Any]]
        if options.includeAllWindows {
            targetWindows = allWindows
        } else if let currentWindowHandle = activePath.windowHandle {
            let currentOnly = allWindows.filter { treeItemMatchesHandle($0, handle: currentWindowHandle) }
            targetWindows = currentOnly.isEmpty ? Array(allWindows.prefix(1)) : currentOnly
        } else {
            targetWindows = Array(allWindows.prefix(1))
        }

        return try targetWindows.map {
            try buildTreeWindowNode(
                window: $0,
                activePath: activePath,
                client: client
            )
        }
    }

    private func treeFallbackWindow(from payload: [String: Any]) -> [String: Any] {
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        let selectedWorkspace = workspaces.first(where: { ($0["selected"] as? Bool) == true })
        return [
            "id": payload["window_id"] ?? NSNull(),
            "ref": payload["window_ref"] ?? NSNull(),
            "index": 0,
            "key": false,
            "visible": true,
            "workspace_count": workspaces.count,
            "selected_workspace_id": selectedWorkspace?["id"] ?? NSNull(),
            "selected_workspace_ref": selectedWorkspace?["ref"] ?? NSNull(),
        ]
    }

    private func buildTreeWindowNode(
        window: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceParams: [String: Any] = [:]
        if let windowHandle = treeItemHandle(window) {
            workspaceParams["window_id"] = windowHandle
        }
        let workspacePayload = try client.sendV2(method: "workspace.list", params: workspaceParams)
        let workspaces = workspacePayload["workspaces"] as? [[String: Any]] ?? []
        let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
        var windowNode = window
        let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
        windowNode["current"] = isActiveWindow
        windowNode["active"] = isActiveWindow
        windowNode["workspaces"] = workspaceNodes
        windowNode["workspace_count"] = workspaceNodes.count
        return windowNode
    }

    private func buildTreeWorkspaceNode(
        workspace: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceNode = workspace
        guard let workspaceHandle = treeItemHandle(workspace) else {
            workspaceNode["panes"] = []
            return workspaceNode
        }

        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceHandle])
        let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceHandle])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
        let browserURLsByHandle = fetchTreeBrowserURLs(
            workspaceHandle: workspaceHandle,
            surfaces: surfaces,
            client: client
        )

        var surfacesByPane: [String: [[String: Any]]] = [:]
        for surface in surfaces {
            var surfaceNode = surface
            if surfaceNode["selected"] == nil {
                surfaceNode["selected"] = (surfaceNode["selected_in_pane"] as? Bool) == true
            }
            surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)

            let surfaceType = ((surfaceNode["type"] as? String) ?? "").lowercased()
            if surfaceType == "browser",
               let url = treeBrowserURL(surface: surfaceNode, urlsByHandle: browserURLsByHandle),
               !url.isEmpty {
                surfaceNode["url"] = url
            } else {
                surfaceNode["url"] = NSNull()
            }

            guard let paneHandle = treeRelatedHandle(surfaceNode, refKey: "pane_ref", idKey: "pane_id") else {
                continue
            }
            surfacesByPane[paneHandle, default: []].append(surfaceNode)
        }

        for paneHandle in surfacesByPane.keys {
            surfacesByPane[paneHandle]?.sort {
                let lhs = intFromAny($0["index_in_pane"]) ?? intFromAny($0["index"]) ?? Int.max
                let rhs = intFromAny($1["index_in_pane"]) ?? intFromAny($1["index"]) ?? Int.max
                return lhs < rhs
            }
        }

        let paneNodes: [[String: Any]] = panes.map { pane in
            var paneNode = pane
            paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)
            if let paneHandle = treeItemHandle(paneNode) {
                paneNode["surfaces"] = surfacesByPane[paneHandle] ?? []
            } else {
                paneNode["surfaces"] = []
            }
            return paneNode
        }

        workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)
        workspaceNode["panes"] = paneNodes
        return workspaceNode
    }

    private func treeItemHandle(_ item: [String: Any]) -> String? {
        if let ref = item["ref"] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func treeRelatedHandle(_ item: [String: Any], refKey: String, idKey: String) -> String? {
        if let ref = item[refKey] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item[idKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func parseTreePath(payload: [String: Any]) -> TreePath {
        return TreePath(
            windowHandle: treeRelatedHandle(payload, refKey: "window_ref", idKey: "window_id"),
            workspaceHandle: treeRelatedHandle(payload, refKey: "workspace_ref", idKey: "workspace_id"),
            paneHandle: treeRelatedHandle(payload, refKey: "pane_ref", idKey: "pane_id"),
            surfaceHandle: treeRelatedHandle(payload, refKey: "surface_ref", idKey: "surface_id")
        )
    }

    private func treeCallerContextFromEnvironment() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let workspaceRaw = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceRaw = env["CMUX_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var caller: [String: Any] = [:]
        if let workspaceRaw, !workspaceRaw.isEmpty {
            caller["workspace_id"] = workspaceRaw
        }
        if let surfaceRaw, !surfaceRaw.isEmpty {
            caller["surface_id"] = surfaceRaw
        }
        return caller.isEmpty ? nil : caller
    }

    private func treePayloadWithMarkers(_ payload: [String: Any]) -> [String: Any] {
        let active = payload["active"] as? [String: Any] ?? [:]
        let caller = payload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: active)
        let callerPath = parseTreePath(payload: caller)
        var result = payload
        let windows = payload["windows"] as? [[String: Any]] ?? []
        result["windows"] = treeApplyMarkers(windows: windows, activePath: activePath, callerPath: callerPath)
        if result["active"] == nil {
            result["active"] = active.isEmpty ? NSNull() : active
        }
        if result["caller"] == nil {
            result["caller"] = caller.isEmpty ? NSNull() : caller
        }
        return result
    }

    private func treeApplyMarkers(
        windows: [[String: Any]],
        activePath: TreePath,
        callerPath: TreePath
    ) -> [[String: Any]] {
        return windows.map { window in
            var windowNode = window
            let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
            windowNode["current"] = isActiveWindow
            windowNode["active"] = isActiveWindow

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let workspaceNodes = workspaces.map { workspace in
                var workspaceNode = workspace
                workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let paneNodes = panes.map { pane in
                    var paneNode = pane
                    paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    paneNode["surfaces"] = surfaces.map { surface in
                        var surfaceNode = surface
                        surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)
                        surfaceNode["here"] = treeItemMatchesHandle(surfaceNode, handle: callerPath.surfaceHandle)
                        return surfaceNode
                    }
                    return paneNode
                }

                workspaceNode["panes"] = paneNodes
                return workspaceNode
            }

            windowNode["workspaces"] = workspaceNodes
            return windowNode
        }
    }

    private func fetchTreeBrowserURLs(
        workspaceHandle: String,
        surfaces: [[String: Any]],
        client: SocketClient
    ) -> [String: String] {
        let hasBrowserSurfaces = surfaces.contains {
            (($0["type"] as? String) ?? "").lowercased() == "browser"
        }
        guard hasBrowserSurfaces else { return [:] }

        if let payload = try? client.sendV2(
            method: "browser.tab.list",
            params: ["workspace_id": workspaceHandle]
        ) {
            let tabs = payload["tabs"] as? [[String: Any]] ?? []
            var urlByHandle: [String: String] = [:]
            for tab in tabs {
                guard let url = tab["url"] as? String, !url.isEmpty else { continue }
                if let id = tab["id"] as? String, !id.isEmpty {
                    urlByHandle[id] = url
                }
                if let ref = tab["ref"] as? String, !ref.isEmpty {
                    urlByHandle[ref] = url
                }
            }
            return urlByHandle
        }

        // Fallback for older servers that may not support browser.tab.list.
        var fallbackURLs: [String: String] = [:]
        for surface in surfaces {
            guard ((surface["type"] as? String) ?? "").lowercased() == "browser" else { continue }
            guard let surfaceHandle = treeItemHandle(surface) else { continue }
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["workspace_id": workspaceHandle, "surface_id": surfaceHandle]
            ),
            let url = payload["url"] as? String,
            !url.isEmpty else {
                continue
            }
            fallbackURLs[surfaceHandle] = url
            if let id = surface["id"] as? String, !id.isEmpty {
                fallbackURLs[id] = url
            }
            if let ref = surface["ref"] as? String, !ref.isEmpty {
                fallbackURLs[ref] = url
            }
        }
        return fallbackURLs
    }

    private func treeBrowserURL(surface: [String: Any], urlsByHandle: [String: String]) -> String? {
        if let id = surface["id"] as? String, let url = urlsByHandle[id] {
            return url
        }
        if let ref = surface["ref"] as? String, let url = urlsByHandle[ref] {
            return url
        }
        if let handle = treeItemHandle(surface), let url = urlsByHandle[handle] {
            return url
        }
        return nil
    }

    private func treeItemMatchesHandle(_ item: [String: Any], handle: String?) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return false
        }
        return (item["id"] as? String) == handle || (item["ref"] as? String) == handle
    }

    private func renderTreeText(windows: [[String: Any]], idFormat: CLIIDFormat) -> String {
        guard !windows.isEmpty else { return "No windows" }

        var lines: [String] = []
        for window in windows {
            lines.append(treeWindowLabel(window, idFormat: idFormat))

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for (workspaceIndex, workspace) in workspaces.enumerated() {
                let workspaceIsLast = workspaceIndex == workspaces.count - 1
                let workspaceBranch = workspaceIsLast ? "└── " : "├── "
                let workspaceIndent = workspaceIsLast ? "    " : "│   "
                lines.append("\(workspaceBranch)\(treeWorkspaceLabel(workspace, idFormat: idFormat))")

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for (paneIndex, pane) in panes.enumerated() {
                    let paneIsLast = paneIndex == panes.count - 1
                    let paneBranch = paneIsLast ? "└── " : "├── "
                    let paneIndent = paneIsLast ? "    " : "│   "
                    lines.append("\(workspaceIndent)\(paneBranch)\(treePaneLabel(pane, idFormat: idFormat))")

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for (surfaceIndex, surface) in surfaces.enumerated() {
                        let surfaceIsLast = surfaceIndex == surfaces.count - 1
                        let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                        lines.append("\(workspaceIndent)\(paneIndent)\(surfaceBranch)\(treeSurfaceLabel(surface, idFormat: idFormat))")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func treeWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["current"] as? Bool) == true {
            parts.append("[current]")
        }
        if (window["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = (workspace["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treePaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]
        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        if (pane["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = ((surface["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = (surface["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (surface["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        if (surface["here"] as? Bool) == true {
            parts.append("◀ here")
        }
        if let tty = surface["tty"] as? String, !tty.isEmpty {
            parts.append("tty=\(tty)")
        }
        if surfaceType.lowercased() == "browser",
           let url = surface["url"] as? String,
           !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func renderTopText(
        payload: [String: Any],
        idFormat: CLIIDFormat,
        showProcesses: Bool,
        sortKey: TopSortKey? = nil
    ) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        guard !windows.isEmpty else { return "No windows" }

        var lines: [String] = ["  CPU%       RSS  PROC  NODE"]
        if let totals = payload["totals"] as? [String: Any] {
            lines.append("\(topResourceColumns(resources: totals))total")
        }

        for window in topSortedItems(windows, sortKey: sortKey, node: { $0 }) {
            lines.append("\(topResourceColumns(node: window))\(topWindowLabel(window, idFormat: idFormat))")

            let workspaces = topSortedItems(window["workspaces"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
            for (workspaceIndex, workspace) in workspaces.enumerated() {
                let workspaceIsLast = workspaceIndex == workspaces.count - 1
                let workspaceBranch = workspaceIsLast ? "└── " : "├── "
                let workspaceIndent = workspaceIsLast ? "    " : "│   "
                lines.append("\(topResourceColumns(node: workspace))\(workspaceBranch)\(topWorkspaceLabel(workspace, idFormat: idFormat))")

                let tags = workspace["tags"] as? [[String: Any]] ?? []
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let workspaceChildren = topSortedItems(
                    tags.map { TopWorkspaceChild.tag($0) } + panes.map { TopWorkspaceChild.pane($0) },
                    sortKey: sortKey,
                    node: { $0.node }
                )

                for (workspaceChildIndex, workspaceChild) in workspaceChildren.enumerated() {
                    let childIsLast = workspaceChildIndex == workspaceChildren.count - 1
                    switch workspaceChild {
                    case .tag(let tag):
                        let tagIsLast = childIsLast
                        let tagBranch = tagIsLast ? "└── " : "├── "
                        let tagIndent = tagIsLast ? "    " : "│   "
                        lines.append("\(topResourceColumns(node: tag))\(workspaceIndent)\(tagBranch)\(topTagLabel(tag))")
                        if showProcesses {
                            appendTopProcessLines(
                                tag["processes"] as? [[String: Any]] ?? [],
                                to: &lines,
                                indent: workspaceIndent + tagIndent,
                                sortKey: sortKey
                            )
                        }
                    case .pane(let pane):
                        let paneIsLast = childIsLast
                        let paneBranch = paneIsLast ? "└── " : "├── "
                        let paneIndent = paneIsLast ? "    " : "│   "
                        lines.append("\(topResourceColumns(node: pane))\(workspaceIndent)\(paneBranch)\(topPaneLabel(pane, idFormat: idFormat))")

                        let surfaces = topSortedItems(pane["surfaces"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
                        for (surfaceIndex, surface) in surfaces.enumerated() {
                            let surfaceIsLast = surfaceIndex == surfaces.count - 1
                            let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                            let surfaceIndent = surfaceIsLast ? "    " : "│   "
                            lines.append("\(topResourceColumns(node: surface))\(workspaceIndent)\(paneIndent)\(surfaceBranch)\(topSurfaceLabel(surface, idFormat: idFormat))")

                            let webviews = topSortedItems(surface["webviews"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
                            let surfaceProcesses = surface["processes"] as? [[String: Any]] ?? []
                            let hasSurfaceProcesses = showProcesses && !surfaceProcesses.isEmpty
                            if !webviews.isEmpty {
                                for (webviewIndex, webview) in webviews.enumerated() {
                                    let webviewIsLast = webviewIndex == webviews.count - 1 && !hasSurfaceProcesses
                                    let webviewBranch = webviewIsLast ? "└── " : "├── "
                                    let webviewIndent = webviewIsLast ? "    " : "│   "
                                    lines.append("\(topResourceColumns(node: webview))\(workspaceIndent)\(paneIndent)\(surfaceIndent)\(webviewBranch)\(topWebViewLabel(webview))")
                                    if showProcesses {
                                        appendTopProcessLines(
                                            webview["processes"] as? [[String: Any]] ?? [],
                                            to: &lines,
                                            indent: workspaceIndent + paneIndent + surfaceIndent + webviewIndent,
                                            sortKey: sortKey
                                        )
                                    }
                                }
                            }
                            if showProcesses {
                                appendTopProcessLines(
                                    surfaceProcesses,
                                    to: &lines,
                                    indent: workspaceIndent + paneIndent + surfaceIndent,
                                    sortKey: sortKey
                                )
                            }
                        }
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private enum TopWorkspaceChild {
        case tag([String: Any])
        case pane([String: Any])

        var node: [String: Any] {
            switch self {
            case .tag(let node), .pane(let node):
                return node
            }
        }
    }

    private func topSortedItems<T>(
        _ items: [T],
        sortKey: TopSortKey?,
        node: (T) -> [String: Any]
    ) -> [T] {
        guard let sortKey else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let lhsValue = topSortValue(node(lhs.element), sortKey: sortKey)
            let rhsValue = topSortValue(node(rhs.element), sortKey: sortKey)
            guard lhsValue != rhsValue else { return lhs.offset < rhs.offset }
            return lhsValue > rhsValue
        }.map(\.element)
    }

    private func topSortValue(_ node: [String: Any], sortKey: TopSortKey) -> Double {
        let resources = node["resources"] as? [String: Any] ?? [:]
        switch sortKey {
        case .cpu:
            let value = topDouble(resources["cpu_percent"])
            return value.isFinite ? value : 0
        case .rss:
            return Double(topInt64(resources["resident_bytes"]))
        case .proc:
            return Double(topInt(resources["process_count"]) ?? 0)
        }
    }

    private struct TopFlatRow {
        let resources: [String: Any]
        let kind: String
        let ref: String
        let parentRef: String
        let title: String
        let ordinal: Int
    }

    private func renderTopFlatTSV(
        payload: [String: Any],
        idFormat: CLIIDFormat,
        showProcesses: Bool,
        sortKey: TopSortKey? = nil
    ) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        guard !windows.isEmpty else { return "" }

        var rows: [TopFlatRow] = []
        var ordinal = 0
        if let totals = payload["totals"] as? [String: Any] {
            appendTopFlatRow(
                resources: totals,
                kind: "total",
                ref: "total",
                parentRef: "",
                title: "",
                ordinal: &ordinal,
                to: &rows
            )
        }

        for window in topSortedItems(windows, sortKey: sortKey, node: { $0 }) {
            let windowRef = topFlatHandle(window, fallback: "window", idFormat: idFormat)
            appendTopFlatNode(
                window,
                kind: "window",
                ref: windowRef,
                parentRef: "total",
                title: "",
                ordinal: &ordinal,
                to: &rows
            )

            let workspaces = topSortedItems(window["workspaces"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
            for workspace in workspaces {
                let workspaceRef = topFlatHandle(workspace, fallback: "workspace", idFormat: idFormat)
                appendTopFlatNode(
                    workspace,
                    kind: "workspace",
                    ref: workspaceRef,
                    parentRef: windowRef,
                    title: workspace["title"] as? String ?? "",
                    ordinal: &ordinal,
                    to: &rows
                )

                let tags = workspace["tags"] as? [[String: Any]] ?? []
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let workspaceChildren = topSortedItems(
                    tags.map { TopWorkspaceChild.tag($0) } + panes.map { TopWorkspaceChild.pane($0) },
                    sortKey: sortKey,
                    node: { $0.node }
                )
                for workspaceChild in workspaceChildren {
                    switch workspaceChild {
                    case .tag(let tag):
                        let tagRef = topFlatHandle(tag, fallback: topLabelText(tag["key"] as? String), idFormat: idFormat)
                        appendTopFlatNode(
                            tag,
                            kind: "tag",
                            ref: tagRef,
                            parentRef: workspaceRef,
                            title: tag["value"] as? String ?? "",
                            ordinal: &ordinal,
                            to: &rows
                        )
                        if showProcesses {
                            appendTopFlatProcesses(
                                tag["processes"] as? [[String: Any]] ?? [],
                                parentRef: tagRef,
                                ordinal: &ordinal,
                                to: &rows,
                                sortKey: sortKey
                            )
                        }
                    case .pane(let pane):
                        let paneRef = topFlatHandle(pane, fallback: "pane", idFormat: idFormat)
                        appendTopFlatNode(
                            pane,
                            kind: "pane",
                            ref: paneRef,
                            parentRef: workspaceRef,
                            title: "",
                            ordinal: &ordinal,
                            to: &rows
                        )

                        let surfaces = topSortedItems(pane["surfaces"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
                        for surface in surfaces {
                            let surfaceRef = topFlatHandle(surface, fallback: "surface", idFormat: idFormat)
                            appendTopFlatNode(
                                surface,
                                kind: "surface",
                                ref: surfaceRef,
                                parentRef: paneRef,
                                title: surface["title"] as? String ?? "",
                                ordinal: &ordinal,
                                to: &rows
                            )

                            let webviews = topSortedItems(surface["webviews"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
                            for webview in webviews {
                                let fallback = topInt(webview["pid"]).map { "pid:\($0)" } ?? "webview"
                                let webviewRef = topFlatHandle(webview, fallback: fallback, idFormat: idFormat)
                                appendTopFlatNode(
                                    webview,
                                    kind: "webview",
                                    ref: webviewRef,
                                    parentRef: surfaceRef,
                                    title: webview["title"] as? String ?? "",
                                    ordinal: &ordinal,
                                    to: &rows
                                )
                                if showProcesses {
                                    appendTopFlatProcesses(
                                        webview["processes"] as? [[String: Any]] ?? [],
                                        parentRef: webviewRef,
                                        ordinal: &ordinal,
                                        to: &rows,
                                        sortKey: sortKey
                                    )
                                }
                            }

                            if showProcesses {
                                appendTopFlatProcesses(
                                    surface["processes"] as? [[String: Any]] ?? [],
                                    parentRef: surfaceRef,
                                    ordinal: &ordinal,
                                    to: &rows,
                                    sortKey: sortKey
                                )
                            }
                        }
                    }
                }
            }
        }

        return rows.map(topFlatTSVLine).joined(separator: "\n")
    }

    private func appendTopFlatNode(
        _ node: [String: Any],
        kind: String,
        ref: String,
        parentRef: String,
        title: String,
        ordinal: inout Int,
        to rows: inout [TopFlatRow]
    ) {
        appendTopFlatRow(
            resources: node["resources"] as? [String: Any] ?? [:],
            kind: kind,
            ref: ref,
            parentRef: parentRef,
            title: title,
            ordinal: &ordinal,
            to: &rows
        )
    }

    private func appendTopFlatProcesses(
        _ processes: [[String: Any]],
        parentRef: String,
        ordinal: inout Int,
        to rows: inout [TopFlatRow],
        sortKey: TopSortKey?
    ) {
        for process in topSortedItems(processes, sortKey: sortKey, node: { $0 }) {
            let processRef = topInt(process["pid"]).map(String.init)
                ?? topFlatHandle(process, fallback: "process", idFormat: .refs)
            appendTopFlatNode(
                process,
                kind: "process",
                ref: processRef,
                parentRef: parentRef,
                title: process["name"] as? String ?? "",
                ordinal: &ordinal,
                to: &rows
            )
            appendTopFlatProcesses(
                process["children"] as? [[String: Any]] ?? [],
                parentRef: processRef,
                ordinal: &ordinal,
                to: &rows,
                sortKey: sortKey
            )
        }
    }

    private func appendTopFlatRow(
        resources: [String: Any],
        kind: String,
        ref: String,
        parentRef: String,
        title: String,
        ordinal: inout Int,
        to rows: inout [TopFlatRow]
    ) {
        rows.append(TopFlatRow(
            resources: resources,
            kind: kind,
            ref: ref,
            parentRef: parentRef,
            title: title,
            ordinal: ordinal
        ))
        ordinal += 1
    }

    private func topFlatHandle(_ node: [String: Any], fallback: String, idFormat: CLIIDFormat) -> String {
        let handle = topLabelText(textHandle(node, idFormat: idFormat))
        if handle != "?" {
            return handle
        }
        let sanitizedFallback = topLabelText(fallback)
        return sanitizedFallback.isEmpty ? "unknown" : sanitizedFallback
    }

    private func topFlatTSVLine(_ row: TopFlatRow) -> String {
        [
            topFlatCPU(row.resources),
            String(topInt64(row.resources["resident_bytes"])),
            String(topInt(row.resources["process_count"]) ?? 0),
            topTSVField(row.kind),
            topTSVField(row.ref),
            topTSVField(row.parentRef),
            topTSVField(row.title),
        ].joined(separator: "\t")
    }

    private func topFlatCPU(_ resources: [String: Any]) -> String {
        let value = topDouble(resources["cpu_percent"])
        guard value.isFinite else { return "0.0" }
        return String(format: "%.1f", value)
    }

    private func topTSVField(_ raw: String) -> String {
        topLabelText(raw)
    }

    private func appendTopProcessLines(
        _ processes: [[String: Any]],
        to lines: inout [String],
        indent: String,
        sortKey: TopSortKey?
    ) {
        let sortedProcesses = topSortedItems(processes, sortKey: sortKey, node: { $0 })
        for (index, process) in sortedProcesses.enumerated() {
            let isLast = index == sortedProcesses.count - 1
            let branch = isLast ? "└── " : "├── "
            let childIndent = isLast ? "    " : "│   "
            lines.append("\(topResourceColumns(node: process))\(indent)\(branch)\(topProcessLabel(process))")
            appendTopProcessLines(
                process["children"] as? [[String: Any]] ?? [],
                to: &lines,
                indent: indent + childIndent,
                sortKey: sortKey
            )
        }
    }

    private func topWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["key"] as? Bool) == true {
            parts.append("[key]")
        }
        if (window["visible"] as? Bool) == false {
            parts.append("[hidden]")
        }
        return parts.joined(separator: " ")
    }

    private func topWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = topLabelText(workspace["title"] as? String)
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["pinned"] as? Bool) == true {
            parts.append("[pinned]")
        }
        return parts.joined(separator: " ")
    }

    private func topPaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]
        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        return parts.joined(separator: " ")
    }

    private func topSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = topLabelText(surface["type"] as? String)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = topLabelText(surface["title"] as? String)
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        let tty = topLabelText(surface["tty"] as? String)
        if !tty.isEmpty {
            parts.append("tty=\(tty)")
        }
        if let pid = topInt(surface["browser_web_content_pid"]) {
            parts.append("webpid=\(pid)")
        }
        let url = topLabelText(surface["url"] as? String)
        if surfaceType.lowercased() == "browser", !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func topTagLabel(_ tag: [String: Any]) -> String {
        let key = topLabelText(tag["key"] as? String)
        let value = topLabelText(tag["value"] as? String)
        var parts = ["tag \(key.isEmpty ? "unknown" : key)"]
        if !value.isEmpty {
            parts.append("\"\(value)\"")
        }
        if (tag["visible"] as? Bool) == false {
            parts.append("[pid-only]")
        }
        if let pid = topInt(tag["pid"]) {
            parts.append("pid=\(pid)")
        }
        return parts.joined(separator: " ")
    }

    private func topWebViewLabel(_ webview: [String: Any]) -> String {
        var parts = ["webview"]
        if let pid = topInt(webview["pid"]) {
            parts.append("pid=\(pid)")
        } else {
            parts.append("pid=unknown")
        }
        if let sharedCount = topInt(webview["shared_process_count"]), sharedCount > 1 {
            parts.append("[shared x\(sharedCount)]")
        }
        let title = topLabelText(webview["title"] as? String)
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        let url = topLabelText(webview["url"] as? String)
        if !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func topProcessLabel(_ process: [String: Any]) -> String {
        let pid = topInt(process["pid"]).map(String.init) ?? "?"
        let name = topLabelText(process["name"] as? String)
        let label = name.isEmpty ? "process" : name
        return "process \(pid) \(label)"
    }

    private func topResourceColumns(node: [String: Any]) -> String {
        topResourceColumns(resources: node["resources"] as? [String: Any] ?? [:])
    }

    private func topResourceColumns(resources: [String: Any]) -> String {
        let cpu = topDouble(resources["cpu_percent"])
        let rss = topInt64(resources["resident_bytes"])
        let count = topInt(resources["process_count"]) ?? 0
        let cpuText = String(format: "%6.1f%%", cpu)
        let rssText = padLeft(formatBytes(rss), width: 9)
        let countText = padLeft(String(count), width: 5)
        return "\(cpuText) \(rssText) \(countText)  "
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private func padLeft(_ value: String, width: Int) -> String {
        guard value.count < width else { return value }
        return String(repeating: " ", count: width - value.count) + value
    }

    private func topInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func topInt64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 {
            return value
        }
        if let value = raw as? Int {
            return Int64(value)
        }
        if let value = raw as? NSNumber {
            return value.int64Value
        }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private func topDouble(_ raw: Any?) -> Double {
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? NSNumber {
            return value.doubleValue
        }
        if let value = raw as? String,
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.sortedKeys)
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private func parseRPCParams(_ args: [String]) throws -> [String: Any] {
        guard !args.isEmpty else { return [:] }
        let raw = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw CLIError(message: "rpc params must be valid UTF-8 JSON")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "rpc params must be valid JSON: \(error.localizedDescription)")
        }
        guard let params = object as? [String: Any] else {
            throw CLIError(message: "rpc params must be a JSON object")
        }
        return params
    }

    private struct TmuxParsedArguments {
        var flags: Set<String> = []
        var options: [String: [String]] = [:]
        var positional: [String] = []

        func hasFlag(_ flag: String) -> Bool {
            flags.contains(flag)
        }

        func value(_ flag: String) -> String? {
            options[flag]?.last
        }
    }

    private func parseTmuxArguments(
        _ args: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) throws -> TmuxParsedArguments {
        var parsed = TmuxParsedArguments()
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let arg = args[index]
            if pastTerminator {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if !arg.hasPrefix("-") || arg == "-" {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                parsed.positional.append(arg)
                index += 1
                continue
            }

            let cluster = Array(arg.dropFirst())
            var cursor = 0
            var recognizedArgument = false
            while cursor < cluster.count {
                let flag = "-" + String(cluster[cursor])
                if boolFlags.contains(flag) {
                    parsed.flags.insert(flag)
                    cursor += 1
                    recognizedArgument = true
                    continue
                }
                if valueFlags.contains(flag) {
                    let remainder = String(cluster.dropFirst(cursor + 1))
                    let value: String
                    if !remainder.isEmpty {
                        value = remainder
                    } else {
                        guard index + 1 < args.count else {
                            throw CLIError(message: "\(flag) requires a value")
                        }
                        index += 1
                        value = args[index]
                    }
                    parsed.options[flag, default: []].append(value)
                    recognizedArgument = true
                    cursor = cluster.count
                    continue
                }

                recognizedArgument = false
                break
            }

            if !recognizedArgument {
                parsed.positional.append(arg)
            }
            index += 1
        }

        return parsed
    }

    private func splitTmuxCommand(_ args: [String]) throws -> (command: String, args: [String]) {
        var index = 0
        let globalValueFlags: Set<String> = ["-L", "-S", "-f"]
        let globalBoolFlags: Set<String> = ["-V", "-v"]

        while index < args.count {
            let arg = args[index]
            if !arg.hasPrefix("-") || arg == "-" {
                return (arg.lowercased(), Array(args.dropFirst(index + 1)))
            }
            if arg == "--" {
                break
            }
            // Handle -V (version) as a pseudo-command
            if globalBoolFlags.contains(arg) {
                return (arg, [])
            }
            if let flag = globalValueFlags.first(where: { arg == $0 || arg.hasPrefix($0) }) {
                if arg == flag {
                    index += 1
                }
            }
            index += 1
        }

        throw CLIError(message: "tmux shim requires a command")
    }

    private func normalizedTmuxTarget(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tmuxWindowSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") || trimmed.hasPrefix("pane:") {
            return nil
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[..<dot])
        }
        return trimmed
    }

    private func tmuxPaneSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("pane:") {
            return trimmed
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dot)...])
        }
        return nil
    }

    private func tmuxWorkspaceItems(client: SocketClient) throws -> [[String: Any]] {
        let payload = try client.sendV2(method: "workspace.list")
        return payload["workspaces"] as? [[String: Any]] ?? []
    }

    private func tmuxCallerWorkspaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"])
    }

    private func tmuxCallerPaneHandle() -> String? {
        guard let pane = normalizedTmuxTarget(ProcessInfo.processInfo.environment["TMUX_PANE"])
            ?? normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_PANE_ID"]) else {
            return nil
        }
        return pane.hasPrefix("%") ? String(pane.dropFirst()) : pane
    }

    private func tmuxCallerSurfaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
    }

    private func tmuxResolvedCallerWorkspaceId(client: SocketClient) -> String? {
        guard let callerWorkspace = tmuxCallerWorkspaceHandle() else {
            return nil
        }
        return try? resolveWorkspaceId(callerWorkspace, client: client)
    }

    private func tmuxCanonicalPaneId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if isUUID(handle) {
            return handle
        }

        let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            if (pane["ref"] as? String) == handle || (pane["id"] as? String) == handle {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for pane in panes where intFromAny(pane["index"]) == index {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Pane target not found")
    }

    private func tmuxCanonicalSurfaceId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            if (surface["ref"] as? String) == handle || (surface["id"] as? String) == handle {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for surface in surfaces where intFromAny(surface["index"]) == index {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Surface target not found")
    }

    private func tmuxWorkspaceIdForPaneHandle(_ handle: String, client: SocketClient) throws -> String? {
        guard isUUID(handle) || isHandleRef(handle) else {
            return nil
        }

        let workspaces = try tmuxWorkspaceItems(client: client)
        for workspace in workspaces {
            guard let workspaceId = workspace["id"] as? String else { continue }
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            if panes.contains(where: { ($0["id"] as? String) == handle || ($0["ref"] as? String) == handle }) {
                return workspaceId
            }
        }

        return nil
    }

    private func tmuxFocusedPaneId(workspaceId: String, client: SocketClient) throws -> String {
        let payload = try client.sendV2(method: "surface.current", params: ["workspace_id": workspaceId])
        if let paneId = payload["pane_id"] as? String {
            return paneId
        }
        if let paneRef = payload["pane_ref"] as? String {
            return try tmuxCanonicalPaneId(paneRef, workspaceId: workspaceId, client: client)
        }
        throw CLIError(message: "Pane target not found")
    }

    private func tmuxResolveWorkspaceTarget(_ raw: String?, client: SocketClient) throws -> String {
        guard var token = normalizedTmuxTarget(raw) else {
            if let callerWorkspace = tmuxCallerWorkspaceHandle() {
                return try resolveWorkspaceId(callerWorkspace, client: client)
            }
            return try resolveWorkspaceId(nil, client: client)
        }

        if token == "!" || token == "^" || token == "-" {
            let payload = try client.sendV2(method: "workspace.last")
            if let workspaceId = payload["workspace_id"] as? String {
                return workspaceId
            }
            throw CLIError(message: "Previous workspace not found")
        }

        if let dot = token.lastIndex(of: ".") {
            token = String(token[..<dot])
        }
        if let colon = token.lastIndex(of: ":") {
            let suffix = token[token.index(after: colon)...]
            token = suffix.isEmpty ? String(token[..<colon]) : String(suffix)
        }
        if token.hasPrefix("@") {
            token = String(token.dropFirst())
        }

        if let resolvedHandle = try? normalizeWorkspaceHandle(token, client: client, allowCurrent: true) {
            return try resolveWorkspaceId(resolvedHandle, client: client)
        }

        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try tmuxWorkspaceItems(client: client)
        if let match = items.first(where: {
            (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }), let id = match["id"] as? String {
            return id
        }

        throw CLIError(message: "Workspace target not found: \(token)")
    }

    private func tmuxResolvePaneTarget(_ raw: String?, client: SocketClient) throws -> (workspaceId: String, paneId: String) {
        let paneSelector = tmuxPaneSelector(from: raw)
        let workspaceSelector = tmuxWindowSelector(from: raw)
        let workspaceId: String = {
            if let workspaceSelector {
                return (try? tmuxResolveWorkspaceTarget(workspaceSelector, client: client)) ?? ""
            }
            if let paneSelector,
               let workspaceId = try? tmuxWorkspaceIdForPaneHandle(paneSelector, client: client) {
                return workspaceId
            }
            return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
        }()
        guard !workspaceId.isEmpty else {
            throw CLIError(message: "Workspace target not found")
        }
        let paneId: String
        if let paneSelector {
            paneId = try tmuxCanonicalPaneId(paneSelector, workspaceId: workspaceId, client: client)
        } else if tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
                  let callerPane = tmuxCallerPaneHandle(),
                  let callerPaneId = try? tmuxCanonicalPaneId(callerPane, workspaceId: workspaceId, client: client) {
            paneId = callerPaneId
        } else {
            paneId = try tmuxFocusedPaneId(workspaceId: workspaceId, client: client)
        }
        return (workspaceId, paneId)
    }

    func tmuxSelectedSurfaceId(
        workspaceId: String,
        paneId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(
            method: "pane.surfaces",
            params: ["workspace_id": workspaceId, "pane_id": paneId]
        )
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        if let selected = surfaces.first(where: { ($0["selected"] as? Bool) == true }),
           let id = selected["id"] as? String {
            return id
        }
        if let first = surfaces.first?["id"] as? String {
            return first
        }
        throw CLIError(message: "Pane has no surface to target")
    }

    private func tmuxResolveSurfaceTarget(
        _ raw: String?,
        client: SocketClient
    ) throws -> (workspaceId: String, paneId: String?, surfaceId: String) {
        if tmuxPaneSelector(from: raw) != nil {
            let resolved = try tmuxResolvePaneTarget(raw, client: client)
            // When the target pane matches the caller's pane, prefer the caller's
            // exact surface (CMUX_SURFACE_ID) over the pane's currently selected
            // surface. The selected surface can change after command startup,
            // but the caller surface stays fixed.
            let callerPane = tmuxCallerPaneHandle()
            let callerSurface = tmuxCallerSurfaceHandle()
            let canonicalCallerPane = callerPane.flatMap { try? tmuxCanonicalPaneId($0, workspaceId: resolved.workspaceId, client: client) }
            let paneMatch = callerPane != nil && (resolved.paneId == callerPane! || resolved.paneId == canonicalCallerPane)
            if paneMatch,
               let callerSurface,
               let surfaceId = try? tmuxCanonicalSurfaceId(
                    callerSurface,
                    workspaceId: resolved.workspaceId,
                    client: client
               ) {
                return (resolved.workspaceId, resolved.paneId, surfaceId)
            }
            let surfaceId = try tmuxSelectedSurfaceId(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                client: client
            )
            return (resolved.workspaceId, resolved.paneId, surfaceId)
        }

        let workspaceId = try tmuxResolveWorkspaceTarget(tmuxWindowSelector(from: raw), client: client)
        if tmuxWindowSelector(from: raw) == nil,
           tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
           let callerSurface = tmuxCallerSurfaceHandle(),
           let surfaceId = try? tmuxCanonicalSurfaceId(
                callerSurface,
                workspaceId: workspaceId,
                client: client
           ) {
            return (workspaceId, nil, surfaceId)
        }
        let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
        return (workspaceId, nil, surfaceId)
    }

    private func tmuxAnchoredSplitTarget(
        workspaceId: String,
        client: SocketClient
    ) -> (targetSurfaceId: String, callerSurfaceId: String?, direction: String)? {
        var store = loadTmuxCompatStore()
        if let lastColumn = store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId {
            if let lastColumnId = try? tmuxCanonicalSurfaceId(
                lastColumn,
                workspaceId: workspaceId,
                client: client
            ) {
                // Once the agent column exists, keep stacking into it even if the
                // caller surface handle has churned from a stale surface:<n> ref.
                return (lastColumnId, nil, "down")
            }

            // Right-column anchors can outlive the pane they pointed at.
            // Drop stale state and rebuild from the caller surface instead.
            store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId = nil
            store.lastSplitSurface.removeValue(forKey: workspaceId)
            try? saveTmuxCompatStore(store)
        }

        let candidateAnchors = [
            tmuxCallerSurfaceHandle(),
            store.mainVerticalLayouts[workspaceId]?.mainSurfaceId
        ].compactMap { $0 }
        for candidate in candidateAnchors {
            if let anchorSurfaceId = try? tmuxCanonicalSurfaceId(
                candidate,
                workspaceId: workspaceId,
                client: client
            ) {
                return (anchorSurfaceId, anchorSurfaceId, "right")
            }
        }

        let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
        let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
        if removedLayout || removedSplit {
            try? saveTmuxCompatStore(store)
        }
        return nil
    }

    private func tmuxRenderFormat(
        _ format: String?,
        context: [String: String],
        fallback: String
    ) -> String {
        guard let format, !format.isEmpty else { return fallback }
        var rendered = format
        for (key, value) in context {
            rendered = rendered.replacingOccurrences(of: "#{\(key)}", with: value)
        }
        rendered = rendered.replacingOccurrences(
            of: "#\\{[^}]+\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func tmuxFormatContext(
        workspaceId: String,
        paneId: String? = nil,
        surfaceId: String? = nil,
        client: SocketClient
    ) throws -> [String: String] {
        let canonicalWorkspaceId = try resolveWorkspaceId(workspaceId, client: client)
        var context: [String: String] = [
            "session_name": "cmux",
            "window_id": "@\(canonicalWorkspaceId)",
            "window_uuid": canonicalWorkspaceId
        ]

        let workspaceItems = try tmuxWorkspaceItems(client: client)
        if let workspace = workspaceItems.first(where: {
            ($0["id"] as? String) == canonicalWorkspaceId || ($0["ref"] as? String) == workspaceId
        }) {
            if let index = intFromAny(workspace["index"]) {
                context["window_index"] = String(index)
            }
            let title = ((workspace["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                context["window_name"] = title
            }
        }

        let currentPayload = try client.sendV2(method: "surface.current", params: ["workspace_id": canonicalWorkspaceId])
        let resolvedPaneId: String? = try {
            if let paneId {
                return try tmuxCanonicalPaneId(paneId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let currentPaneId = currentPayload["pane_id"] as? String {
                return currentPaneId
            }
            if let currentPaneRef = currentPayload["pane_ref"] as? String {
                return try tmuxCanonicalPaneId(currentPaneRef, workspaceId: canonicalWorkspaceId, client: client)
            }
            return nil
        }()
        let resolvedSurfaceId: String? = try {
            if let surfaceId {
                return try tmuxCanonicalSurfaceId(surfaceId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let resolvedPaneId {
                return try tmuxSelectedSurfaceId(
                    workspaceId: canonicalWorkspaceId,
                    paneId: resolvedPaneId,
                    client: client
                )
            }
            return currentPayload["surface_id"] as? String
        }()

        if let resolvedPaneId {
            context["pane_id"] = "%\(resolvedPaneId)"
            context["pane_uuid"] = resolvedPaneId
            let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": canonicalWorkspaceId])
            let panes = panePayload["panes"] as? [[String: Any]] ?? []
            if let pane = panes.first(where: { ($0["id"] as? String) == resolvedPaneId }),
               let index = intFromAny(pane["index"]) {
                context["pane_index"] = String(index)
            }
        }

        if let resolvedSurfaceId {
            context["surface_id"] = resolvedSurfaceId
            let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": canonicalWorkspaceId])
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            if let surface = surfaces.first(where: { ($0["id"] as? String) == resolvedSurfaceId }) {
                let title = ((surface["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    context["pane_title"] = title
                    context["window_name"] = context["window_name"] ?? title
                }
                let paneStartCommand = [
                    surface["tmux_start_command"],
                    surface["pane_start_command"],
                    surface["initial_command"]
                ]
                    .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let paneStartCommand {
                    context["pane_start_command"] = paneStartCommand
                    if let currentCommand = tmuxCurrentCommandName(from: paneStartCommand) {
                        context["pane_current_command"] = currentCommand
                    }
                }
            }
        }

        return context
    }

    private func tmuxCompatResolvedSocketPath(processEnvironment: [String: String]) throws -> String {
        let envSocketPath = try CLISocketEnvironment.socketPath(in: processEnvironment)

        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }

        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment
        )
    }

    private func tmuxCompatStoreURL() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
            ?? NSString(string: "~").expandingTildeInPath
        return URL(fileURLWithPath: homePath)
            .appendingPathComponent(".cmuxterm")
            .appendingPathComponent("tmux-compat-store.json")
    }

    private func loadTmuxCompatStore() -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return TmuxCompatStore()
        }
        return decoded
    }

    private func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }

    private func tmuxPruneCompatWorkspaceState(workspaceId: String) throws {
        var store = loadTmuxCompatStore()
        let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
        let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
        if removedLayout || removedSplit {
            try saveTmuxCompatStore(store)
        }
    }

    private func tmuxCompatPaneAnchorSurfaceId(_ pane: [String: Any]) -> String? {
        if let selected = pane["selected_surface_id"] as? String, !selected.isEmpty {
            return selected
        }
        let surfaceIds = pane["surface_ids"] as? [String] ?? []
        return surfaceIds.first
    }

    private func tmuxCompatPanePixelFrame(_ pane: [String: Any]) -> (x: Double, y: Double)? {
        guard let frame = pane["pixel_frame"] as? [String: Any],
              let x = doubleFromAny(frame["x"]),
              let y = doubleFromAny(frame["y"]) else {
            return nil
        }
        return (x, y)
    }

    private func tmuxReplacementColumnSurfaceId(
        workspaceId: String,
        layout: MainVerticalState,
        client: SocketClient
    ) -> String? {
        guard let payload = try? client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId]) else {
            return nil
        }
        let panes = payload["panes"] as? [[String: Any]] ?? []
        guard !panes.isEmpty else { return nil }

        guard let mainPane = panes.first(where: { pane in
            let surfaceIds = pane["surface_ids"] as? [String] ?? []
            if surfaceIds.contains(layout.mainSurfaceId) {
                return true
            }
            return (pane["selected_surface_id"] as? String) == layout.mainSurfaceId
        }) else {
            return nil
        }

        let mainPaneId = mainPane["id"] as? String
        let nonMainPanes = panes.filter { ($0["id"] as? String) != mainPaneId }
        guard !nonMainPanes.isEmpty else { return nil }

        let candidatePanes: [[String: Any]]
        if let mainFrame = tmuxCompatPanePixelFrame(mainPane) {
            let rightColumn = nonMainPanes.filter { pane in
                guard let frame = tmuxCompatPanePixelFrame(pane) else { return false }
                return frame.x > mainFrame.x + 0.5
            }
            candidatePanes = rightColumn.isEmpty ? nonMainPanes : rightColumn
        } else {
            candidatePanes = nonMainPanes
        }

        let bottomMostPane = candidatePanes.max { lhs, rhs in
            let lhsFrame = tmuxCompatPanePixelFrame(lhs)
            let rhsFrame = tmuxCompatPanePixelFrame(rhs)
            switch (lhsFrame, rhsFrame) {
            case let (.some(lhsFrame), .some(rhsFrame)):
                if lhsFrame.y == rhsFrame.y {
                    return lhsFrame.x < rhsFrame.x
                }
                return lhsFrame.y < rhsFrame.y
            case (.none, .some):
                return true
            case (.some, .none):
                return false
            case (.none, .none):
                return false
            }
        }

        return bottomMostPane.flatMap { tmuxCompatPaneAnchorSurfaceId($0) }
    }

    private func tmuxPruneCompatSurfaceState(
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) throws {
        var store = loadTmuxCompatStore()
        var changed = false

        if store.lastSplitSurface[workspaceId] == surfaceId {
            store.lastSplitSurface.removeValue(forKey: workspaceId)
            changed = true
        }

        if let layout = store.mainVerticalLayouts[workspaceId] {
            if layout.mainSurfaceId == surfaceId {
                store.mainVerticalLayouts.removeValue(forKey: workspaceId)
                store.lastSplitSurface.removeValue(forKey: workspaceId)
                changed = true
            } else if layout.lastColumnSurfaceId == surfaceId {
                var updatedLayout = layout
                let replacementSurfaceId = tmuxReplacementColumnSurfaceId(
                    workspaceId: workspaceId,
                    layout: layout,
                    client: client
                )
                updatedLayout.lastColumnSurfaceId = replacementSurfaceId
                store.mainVerticalLayouts[workspaceId] = updatedLayout
                if let replacementSurfaceId {
                    store.lastSplitSurface[workspaceId] = replacementSurfaceId
                } else {
                    store.lastSplitSurface.removeValue(forKey: workspaceId)
                }
                changed = true
            }
        }

        if changed {
            try saveTmuxCompatStore(store)
        }
    }

    private func runShellCommand(_ command: String, stdinText: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if let data = stdinText.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func tmuxWaitForSignalURL(name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return URL(fileURLWithPath: "/tmp/cmux-wait-for-\(String(sanitized)).sig")
    }

    private func runTmuxCompatCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        switch command {
        case "capture-pane":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let workspaceArg = wsArg ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "resize-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let amountArg = optionValue(commandArgs, name: "--amount")
            let amount = Int(amountArg ?? "1") ?? 1
            if amount <= 0 {
                throw CLIError(message: "--amount must be greater than 0")
            }

            let direction: String = {
                if commandArgs.contains("-L") { return "left" }
                if commandArgs.contains("-R") { return "right" }
                if commandArgs.contains("-U") { return "up" }
                if commandArgs.contains("-D") { return "down" }
                return "right"
            }()

            var params: [String: Any] = ["direction": direction, "amount": amount]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.resize", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "pipe-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (cmdOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText: String = {
                if let cmdOpt { return cmdOpt }
                let trimmed = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }()
            guard !commandText.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }

            var params: [String: Any] = ["scrollback": true]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            let shell = try runShellCommand(commandText, stdinText: text)
            if shell.status != 0 {
                throw CLIError(message: "pipe-pane command failed (\(shell.status)): \(shell.stderr)")
            }
            if jsonOutput {
                print(jsonString([
                    "ok": true,
                    "status": shell.status,
                    "stdout": shell.stdout,
                    "stderr": shell.stderr
                ]))
            } else {
                if !shell.stdout.isEmpty {
                    print(shell.stdout, terminator: "")
                }
                print("OK")
            }

        case "wait-for":
            let signal = commandArgs.contains("-S") || commandArgs.contains("--signal")
            let timeoutRaw = optionValue(commandArgs, name: "--timeout")
            let timeout = timeoutRaw.flatMap { Double($0) } ?? 30.0
            let name = commandArgs.first(where: { !$0.hasPrefix("-") }) ?? ""
            guard !name.isEmpty else {
                throw CLIError(message: "wait-for requires a name")
            }
            let signalURL = tmuxWaitForSignalURL(name: name)
            if signal {
                FileManager.default.createFile(atPath: signalURL.path, contents: Data())
                print("OK")
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            do {
                try SocketClient.waitForFilesystemPath(signalURL.path, timeout: max(0, deadline.timeIntervalSinceNow))
                try? FileManager.default.removeItem(at: signalURL)
                print("OK")
                return
            } catch {
                if FileManager.default.fileExists(atPath: signalURL.path) {
                    try? FileManager.default.removeItem(at: signalURL)
                    print("OK")
                    return
                }
            }
            throw CLIError(message: "wait-for timed out waiting for '\(name)'")

        case "swap-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            guard let sourcePaneRaw = optionValue(commandArgs, name: "--pane") else {
                throw CLIError(message: "swap-pane requires --pane")
            }
            guard let targetPaneRaw = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "swap-pane requires --target-pane")
            }
            let focusRaw = optionValue(commandArgs, name: "--focus")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePane = try normalizePaneHandle(sourcePaneRaw, client: client, workspaceHandle: wsId)
            let targetPane = try normalizePaneHandle(targetPaneRaw, client: client, workspaceHandle: wsId)
            if let sourcePane { params["pane_id"] = sourcePane }
            if let targetPane { params["target_pane_id"] = targetPane }
            try applyFocusOption(focusRaw, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "pane.swap", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "break-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let focusRaw = optionValue(commandArgs, name: "--focus")
            try rejectConflictingFocusFlags(commandArgs)
            var params: [String: Any] = [:]
            try applyFocusOption(focusRaw, defaultValue: false, to: &params)
            if commandArgs.contains("--no-focus") {
                params["focus"] = false
            }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.break", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "join-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let sourcePaneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            guard let targetPaneArg = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "join-pane requires --target-pane")
            }
            let focusRaw = optionValue(commandArgs, name: "--focus")
            try rejectConflictingFocusFlags(commandArgs)
            var params: [String: Any] = [:]
            try applyFocusOption(focusRaw, defaultValue: false, to: &params)
            if commandArgs.contains("--no-focus") {
                params["focus"] = false
            }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePaneId = try normalizePaneHandle(sourcePaneArg, client: client, workspaceHandle: wsId)
            if let sourcePaneId { params["pane_id"] = sourcePaneId }
            let targetPaneId = try normalizePaneHandle(targetPaneArg, client: client, workspaceHandle: wsId)
            if let targetPaneId { params["target_pane_id"] = targetPaneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.join", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "last-window":
            let payload = try client.sendV2(method: "workspace.last")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "next-window":
            let payload = try client.sendV2(method: "workspace.next")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "previous-window":
            let payload = try client.sendV2(method: "workspace.previous")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "last-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.last", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "find-window":
            let includeContent = commandArgs.contains("--content")
            let shouldSelect = commandArgs.contains("--select")
            let query = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let listPayload = try client.sendV2(method: "workspace.list")
            let workspaces = listPayload["workspaces"] as? [[String: Any]] ?? []

            var matches: [[String: Any]] = []
            for ws in workspaces {
                let title = (ws["title"] as? String) ?? ""
                let titleMatch = query.isEmpty || title.localizedCaseInsensitiveContains(query)
                var contentMatch = false
                if includeContent && !query.isEmpty, let wsId = ws["id"] as? String {
                    let textPayload = try? client.sendV2(method: "surface.read_text", params: ["workspace_id": wsId])
                    let text = (textPayload?["text"] as? String) ?? ""
                    contentMatch = text.localizedCaseInsensitiveContains(query)
                }
                if titleMatch || contentMatch {
                    matches.append(ws)
                }
            }

            if shouldSelect, let first = matches.first, let wsId = first["id"] as? String {
                _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": wsId])
            }

            if jsonOutput {
                let formatted = formatIDs(["matches": matches], mode: idFormat) as? [String: Any]
                print(jsonString(["matches": formatted?["matches"] ?? []]))
            } else if matches.isEmpty {
                print("No matches")
            } else {
                for item in matches {
                    let handle = textHandle(item, idFormat: idFormat)
                    let title = (item["title"] as? String) ?? ""
                    print("\(handle)  \"\(title)\"")
                }
            }

        case "clear-history":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.clear_history", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "set-hook":
            var store = loadTmuxCompatStore()
            if commandArgs.contains("--list") {
                if jsonOutput {
                    print(jsonString(["hooks": store.hooks]))
                } else if store.hooks.isEmpty {
                    print("No hooks configured")
                } else {
                    for (event, hookCmd) in store.hooks.sorted(by: { $0.key < $1.key }) {
                        print("\(event) -> \(hookCmd)")
                    }
                }
                return
            }
            if commandArgs.contains("--unset") {
                guard let event = commandArgs.last else {
                    throw CLIError(message: "set-hook --unset requires an event name")
                }
                store.hooks.removeValue(forKey: event)
                try saveTmuxCompatStore(store)
                print("OK")
                return
            }
            guard let event = commandArgs.first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            let commandText = commandArgs.drop(while: { $0 != event }).dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandText.isEmpty else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            store.hooks[event] = commandText
            try saveTmuxCompatStore(store)
            print("OK")

        case "popup":
            throw CLIError(message: "popup is not supported yet in cmux CLI parity mode")

        case "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in cmux CLI parity mode")

        case "set-buffer":
            let (nameArg, rem0) = parseOption(commandArgs, name: "--name")
            let name = (nameArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? nameArg! : "default"
            let content = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "set-buffer requires text")
            }
            var store = loadTmuxCompatStore()
            store.buffers[name] = content
            try saveTmuxCompatStore(store)
            print("OK")

        case "list-buffers":
            let store = loadTmuxCompatStore()
            if jsonOutput {
                let payload = store.buffers.map { key, value in ["name": key, "size": value.count] }
                print(jsonString(["buffers": payload.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]))
            } else if store.buffers.isEmpty {
                print("No buffers")
            } else {
                for key in store.buffers.keys.sorted() {
                    let size = store.buffers[key]?.count ?? 0
                    print("\(key)\t\(size)")
                }
            }

        case "paste-buffer":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let name = optionValue(commandArgs, name: "--name") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            var params: [String: Any] = ["text": buffer]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "respawn-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText = (commandOpt ?? rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCommand = commandText.isEmpty ? "exec ${SHELL:-/bin/zsh} -l" : commandText
            var params: [String: Any] = ["text": finalCommand + "\n"]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "display-message":
            let printOnly = commandArgs.contains("-p") || commandArgs.contains("--print")
            let message = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw CLIError(message: "display-message requires text")
            }
            if printOnly {
                print(message)
                return
            }
            if jsonOutput {
                print(jsonString(["message": message]))
            } else {
                print(message)
            }

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    private func versionSummary() -> String {
        let info = resolvedVersionInfo()
        let commit = info["CMUXCommit"].flatMap { normalizedCommitHash($0) }
        let baseSummary: String
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            baseSummary = "cmux \(version) (\(build))"
        } else if let version = info["CFBundleShortVersionString"] {
            baseSummary = "cmux \(version)"
        } else if let build = info["CFBundleVersion"] {
            baseSummary = "cmux build \(build)"
        } else {
            baseSummary = "cmux version unknown"
        }
        guard let commit else { return baseSummary }
        return "\(baseSummary) [\(commit)]"
    }

    private func printWelcome() {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        func trueColor(_ red: Int, _ green: Int, _ blue: Int) -> String {
            "\u{001B}[38;2;\(red);\(green);\(blue)m"
        }

        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        let c1 = trueColor(0, 212, 255)
        let c2 = trueColor(24, 181, 250)
        let c3 = trueColor(48, 150, 245)
        let c4 = trueColor(72, 119, 241)
        let c5 = trueColor(96, 88, 239)
        let c6 = trueColor(110, 73, 238)
        let c7 = trueColor(124, 58, 237)

        let tagline: String
        let subdued: String

        if isDark {
            tagline = trueColor(130, 130, 140)
            subdued = "\u{001B}[2m"
        } else {
            tagline = trueColor(90, 90, 98)
            subdued = trueColor(100, 100, 108)
        }

        let logo = """
        \(c1)  ::\(reset)
        \(c2)    ::::\(reset)              \(c1)c\(c2)m\(c3)u\(c7)x\(reset)
        \(c3)      ::::::\(reset)
        \(c4)        ::::::\(reset)        \(tagline)the open source terminal\(reset)
        \(c5)      ::::::\(reset)          \(tagline)workspace-first terminal\(reset)
        \(c6)    ::::\(reset)
        \(c7)  ::\(reset)
        """

        let shortcuts = """
          \(bold)Shortcuts\(reset)

          \(bold)\u{2318}N\(reset)\(subdued)                  New workspace\(reset)
          \(bold)\u{2318}T\(reset)\(subdued)                  New tab\(reset)
          \(bold)\u{2318}P\(reset)\(subdued)                  Go to workspace\(reset)
          \(bold)\u{2318}B\(reset)\(subdued)                  Toggle Left Sidebar\(reset)
          \(bold)\u{2318}\u{2325}B\(reset)\(subdued)                 Toggle Right Sidebar\(reset)
          \(bold)\u{2318}D\(reset)\(subdued)                  Split right\(reset)
          \(bold)\u{2318}\u{21E7}D\(reset)\(subdued)                 Split down\(reset)
          \(bold)\u{2318}\u{21E7}P\(reset)\(subdued)                 Command palette\(reset)
          \(bold)\u{2318}\u{21E7}R\(reset)\(subdued)                 Rename workspace\(reset)
          \(bold)\u{2318}\u{21E7}L\(reset)\(subdued)                 New browser\(reset)
        """

        print()
        print(logo)
        print()
        print(shortcuts)
        print()
        print("  \(bold)Docs\(reset)\(subdued)                https://cmux.com/docs\(reset)")
        print("  \(bold)Discord\(reset)\(subdued)             https://discord.gg/xsgFEVrWCZ\(reset)")
        print("  \(bold)GitHub\(reset)\(subdued)              https://github.com/manaflow-ai/cmux (please leave a star ⭐)\(reset)")
        print("  \(bold)Email\(reset)\(subdued)               founders@manaflow.com\(reset)")
        print()
        print("  \(subdued)Run \(reset)\(bold)cmux --help\(reset)\(subdued) for all commands.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)cmux shortcuts\(reset)\(subdued) to edit shortcuts.\(reset)")
        print()
    }

    private func resolvedVersionInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            info.merge(main, uniquingKeysWith: { current, _ in current })
        }

        let needsPlistFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsPlistFallback {
            for plistURL in candidateInfoPlistURLs() {
                guard let data = try? Data(contentsOf: plistURL),
                      let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dictionary = raw as? [String: Any],
                      let parsed = versionInfo(from: dictionary)
                else {
                    continue
                }
                info.merge(parsed, uniquingKeysWith: { current, _ in current })
                if info["CFBundleShortVersionString"] != nil,
                   info["CFBundleVersion"] != nil,
                   info["CMUXCommit"] != nil {
                    break
                }
            }
        }

        let needsProjectFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsProjectFallback, let fromProject = versionInfoFromProjectFile() {
            info.merge(fromProject, uniquingKeysWith: { current, _ in current })
        }

        if info["CMUXCommit"] == nil,
           let commit = normalizedCommitHash(ProcessInfo.processInfo.environment["CMUX_COMMIT"]) {
            info["CMUXCommit"] = commit
        }

        return info
    }

    private func versionInfo(from dictionary: [String: Any]?) -> [String: String]? {
        guard let dictionary else { return nil }

        var info: [String: String] = [:]
        if let version = dictionary["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleShortVersionString"] = trimmed
            }
        }
        if let build = dictionary["CFBundleVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleVersion"] = trimmed
            }
        }
        if let commit = dictionary["CMUXCommit"] as? String,
           let normalizedCommit = normalizedCommitHash(commit) {
            info["CMUXCommit"] = normalizedCommit
        }
        return info.isEmpty ? nil : info
    }

    private func versionInfoFromProjectFile() -> [String: String]? {
        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        let fileManager = FileManager.default
        var current = executableURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let projectFile = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path),
               let contents = try? String(contentsOf: projectFile, encoding: .utf8) {
                var info: [String: String] = [:]
                if let version = firstProjectSetting("MARKETING_VERSION", in: contents) {
                    info["CFBundleShortVersionString"] = version
                }
                if let build = firstProjectSetting("CURRENT_PROJECT_VERSION", in: contents) {
                    info["CFBundleVersion"] = build
                }
                if let commit = gitCommitHash(at: current) {
                    info["CMUXCommit"] = commit
                }
                if !info.isEmpty {
                    return info
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    private func firstProjectSetting(_ key: String, in source: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        let value = source[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    private func gitCommitHash(at directory: URL) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(output)
    }

    private func normalizedCommitHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        let normalized = trimmed.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return String(normalized.prefix(12))
    }

    // Foundation can walk past "/" into "/.." when repeatedly deleting path
    // components, so stop once the canonical root is reached.
    func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    private func candidateInfoPlistURLs() -> [URL] {
        guard let executableURL = resolvedExecutableURL() else {
            return []
        }

        let fileManager = FileManager.default

        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendIfExisting(_ url: URL) {
            let path = url.path
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            candidates.append(url)
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app" {
                appendIfExisting(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                appendIfExisting(current.appendingPathComponent("Info.plist"))
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                appendIfExisting(repoInfo)
                break
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        // If we already found an ancestor bundle or repo Info.plist, avoid scanning
        // sibling app bundles. Large Resources directories can otherwise balloon RSS.
        guard candidates.isEmpty else {
            return candidates
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent().standardizedFileURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        ]
        for root in searchRoots {
            guard let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let entry as URL in entries where entry.pathExtension == "app" {
                appendIfExisting(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        return candidates
    }

    private func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return Bundle.main.executableURL?.path ?? args.first
    }

    func resolvedExecutableURL() -> URL? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let expanded = (executable as NSString).expandingTildeInPath
        if let resolvedPath = realpath(expanded, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func usage() -> String {
        return """
        cmux - control cmux via Unix socket

        Usage:
          cmux <path>                Open a directory in a new workspace (launches cmux if needed)
          cmux [global-options] <command> [options]

        Handle Inputs:
          Use UUIDs, short refs (window:1/workspace:2/pane:3/surface:4), or indexes where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD env var, then password saved in Settings.

        Workspace Help:
          To change cmux settings, run `cmux docs settings` and `cmux settings path`; to add Dock controls, run `cmux docs dock`.
          Back up any existing cmux.json file to a timestamped .bak copy before editing.
          Use printed curl commands to fetch the latest docs/schema, and prefer Ghostty config for terminal behavior Ghostty already supports.
          Ghostty config lives at ~/.config/ghostty/config (controls terminal transparency, blur, font, theme, keybinds, etc.).
          `cmux reload-config` reloads BOTH Ghostty config and ~/.config/cmux/cmux.json and refreshes terminals in place. No app restart needed.

        Commands:
          welcome
          docs [settings|shortcuts|api|browser|dock]
          settings [open [target]|path|docs|<target>]
          config <doctor|check|validate|path|paths|docs|documentation|reload>
          shortcuts
          disable-browser | enable-browser | browser-status
          restore-session
          themes [list|set|clear]
          ping
          version
          capabilities
          events [--after <seq>] [--cursor-file <path>] [--name <event>] [--category <category>] [--reconnect] [--limit <n>] [--no-ack] [--no-heartbeat]
          auth <status|login|logout>
          login | logout                                      (aliases for auth login/logout)
          rpc <method> [json-params]
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          workspace-action --action <name> [--workspace <id|ref|index>] [--title <text>] [--color <name|#hex>] [--description <text>]
          move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--focus <true|false>]
          list-workspaces
          new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>] [--window <id|ref|index>] [--focus <true|false>]
          new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>] [--focus <true|false>]
          list-panes [--workspace <id|ref>]
          list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]
          tree [--all] [--workspace <id|ref|index>]
          top [--all] [--workspace <id|ref|index>] [--processes] [--sort <cpu|rss|proc>] [--flat] [--format <tree|tsv>]
          focus-pane --pane <id|ref> [--workspace <id|ref>]
          new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>] [--focus <true|false>]
          new-surface [--type <terminal|browser>] [--pane <id|ref>] [--workspace <id|ref>] [--url <url>] [--focus <true|false>]
          close-surface [--surface <id|ref>] [--workspace <id|ref>]
          move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          split-off --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--focus <true|false>]
          reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--focus <true|false>]
          tab-action --action <name> [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--url <url>] [--focus <true|false>]
          rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>
          drag-surface-to-split --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--focus <true|false>]
          refresh-surfaces
          reload-config
          surface-health [--workspace <id|ref>]
          debug-terminals
          list-panels [--workspace <id|ref>]
          focus-panel --panel <id|ref> [--workspace <id|ref>]
          close-workspace --workspace <id|ref>
          select-workspace --workspace <id|ref>
          rename-workspace [--workspace <id|ref>] <title>
          rename-window [--workspace <id|ref>] <title>
          current-workspace
          read-screen [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          send [--workspace <id|ref>] [--surface <id|ref>] <text>
          send-key [--workspace <id|ref>] [--surface <id|ref>] <key>
          send-panel --panel <id|ref> [--workspace <id|ref>] <text>
          send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>
          right-sidebar <toggle|show|hide|focus|set|mode|files|find|dock> [--workspace <id|ref|index>] [--window <id|ref|index>] [--no-focus]
          sidebar-state [--workspace <id|ref>]

          # tmux compatibility commands
          capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]
          pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]
          wait-for [-S|--signal] <name> [--timeout <seconds>]
          swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>] [--focus <true|false>]
          break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]
          join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]
          next-window | previous-window | last-window
          last-pane [--workspace <id|ref>]
          find-window [--content] [--select] <query>
          clear-history [--workspace <id|ref>] [--surface <id|ref>]
          set-hook [--list] [--unset <event>] | <event> <command>
          popup
          bind-key | unbind-key | copy-mode
          set-buffer [--name <name>] <text>
          list-buffers
          paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]
          respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd>]
          display-message [-p|--print] <text>

          markdown [open] <path> [--focus <true|false>] (open markdown file in formatted viewer panel with live reload)

          browser [--surface <id|ref|index> | <surface>] <subcommand> ...
          browser disable | enable | status
          browser open [url] [--focus <true|false>] (create browser split in caller's workspace; if surface supplied, behaves like navigate)
          browser open-split [url]
          browser goto|navigate <url> [--snapshot-after]
          browser back|forward|reload [--snapshot-after]
          browser url|get-url
          browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
          browser eval <script>
          browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]
          browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]
          browser type <selector> <text> [--snapshot-after]
          browser fill <selector> [text] [--snapshot-after]   (empty text clears input)
          browser press|keydown|keyup <key> [--snapshot-after]
          browser select <selector> <value> [--snapshot-after]
          browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
          browser screenshot [--out <path>] [--json]
          browser get <url|title|text|html|value|attr|count|box|styles> [...]
          browser is <visible|enabled|checked> <selector>
          browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...
          browser frame <selector|main>
          browser dialog <accept|dismiss> [text]
          browser download [wait] [--path <path>] [--timeout-ms <ms>]
          browser profiles <list|add|rename|clear|delete> [...]
          browser profiles clear <profile|--all> [--force]
          browser import [...]
          browser cookies <get|set|clear> [...]
          browser storage <local|session> <get|set|clear> [...]
          browser tab <new|list|switch|close|<index>> [...]
          browser console <list|clear>
          browser errors <list|clear>
          browser highlight <selector>
          browser state <save|load> <path>
          browser addinitscript <script>
          browser addscript <script>
          browser addstyle <css>
          browser identify [--surface <id|ref|index>]
          help

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in cmux terminals. Used as default --workspace for
                              workspace and surface commands such as send, list-panels, and new-split.
          CMUX_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          CMUX_SURFACE_ID     Auto-set in cmux terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/cmux/cmux.sock and auto-discovers tagged/debug sockets.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }
#endif
}

private enum CMUXCLIOutput {
    static func writeStandardError(_ message: String) {
        write(Data(message.utf8), to: STDERR_FILENO)
    }

    private static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var offset = 0
            while offset < data.count {
                let bytesWritten = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if bytesWritten > 0 {
                    offset += bytesWritten
                } else if bytesWritten == -1, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = CMUXCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            CMUXCLIOutput.writeStandardError("Error: \(error)\n")
            let exitCode = (error as? CLIError)?.exitCode ?? 1
            exit(exitCode)
        }
    }
}
