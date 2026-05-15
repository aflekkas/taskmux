import AppKit
import CryptoKit
import Foundation

struct WorkspaceGitContext: Codable, Equatable, Hashable, Sendable {
    var repoRoot: String
    var worktreePath: String?
    var baseRef: String?
    var branch: String?
    var headCommit: String?
    var isDetached: Bool
    var isDirty: Bool
    var isManaged: Bool
    var taskTitle: String?
    var taskId: String?
    var externalURLString: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    var activeDirectory: String {
        let trimmedWorktree = worktreePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedWorktree.isEmpty {
            return trimmedWorktree
        }
        return repoRoot
    }

    var displayBranch: String {
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            return "\(branch)\(isDirty ? "*" : "")"
        }
        if let headCommit = headCommit?.trimmingCharacters(in: .whitespacesAndNewlines), !headCommit.isEmpty {
            let detached = String(localized: "gitContext.display.detached", defaultValue: "detached")
            return "\(detached) @ \(String(headCommit.prefix(7)))\(isDirty ? "*" : "")"
        }
        return isDetached
            ? String(localized: "gitContext.display.detached", defaultValue: "detached")
            : String(localized: "gitContext.display.git", defaultValue: "git")
    }

    func payload() -> [String: Any] {
        [
            "repo_root": repoRoot,
            "worktree_path": worktreePath ?? NSNull(),
            "active_directory": activeDirectory,
            "base_ref": baseRef ?? NSNull(),
            "branch": branch ?? NSNull(),
            "head_commit": headCommit ?? NSNull(),
            "is_detached": isDetached,
            "is_dirty": isDirty,
            "is_managed": isManaged,
            "task_title": taskTitle ?? NSNull(),
            "task_id": taskId ?? NSNull(),
            "external_url": externalURLString ?? NSNull(),
            "created_at": createdAt,
            "updated_at": updatedAt
        ]
    }
}

enum WorkspaceGitContextError: LocalizedError {
    case notGitRepository(String)
    case commandFailed(command: String, detail: String)
    case worktreePathUnavailable
    case branchAlreadyCheckedOut(branch: String, path: String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository(let path):
            return String(
                format: String(localized: "gitContext.error.notGitRepository", defaultValue: "No git repository was found at %@."),
                locale: .current,
                path
            )
        case .commandFailed(let command, let detail):
            return String(
                format: String(localized: "gitContext.error.commandFailed", defaultValue: "%@ failed: %@"),
                locale: .current,
                command,
                detail
            )
        case .worktreePathUnavailable:
            return String(localized: "gitContext.error.worktreePathUnavailable", defaultValue: "Taskmux could not choose a managed worktree path.")
        case .branchAlreadyCheckedOut(let branch, let path):
            return String(
                format: String(localized: "gitContext.error.branchAlreadyCheckedOut", defaultValue: "Branch %@ is already checked out at %@."),
                locale: .current,
                branch,
                path
            )
        }
    }
}

enum WorkspaceGitContextManager {
    private struct CommandResult: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    private struct WorktreeEntry {
        var path: String
        var branch: String?
        var head: String?
        var detached: Bool
    }

    static func createManagedContext(
        sourceDirectory: String,
        workspaceTitle: String,
        branch requestedBranch: String? = nil,
        baseRef requestedBaseRef: String? = nil,
        taskTitle: String? = nil,
        taskId: String? = nil,
        externalURLString: String? = nil
    ) async throws -> WorkspaceGitContext {
        let sourceRoot = try await repositoryRoot(for: sourceDirectory)
        let baseRef = normalized(requestedBaseRef) ?? "HEAD"
        let branch = normalized(requestedBranch) ?? "taskmux/\(slug(taskId ?? taskTitle ?? workspaceTitle))"
        let existingWorktrees = try await listWorktrees(repositoryDirectory: sourceRoot)
        if let checkedOut = existingWorktrees.first(where: { normalizedBranch($0.branch) == branch }) {
            let context = try await inspectContext(
                directory: checkedOut.path,
                repoRoot: sourceRoot,
                isManaged: managedRootContains(checkedOut.path, sourceRoot: sourceRoot),
                taskTitle: taskTitle,
                taskId: taskId,
                externalURLString: externalURLString,
                baseRef: baseRef,
                createdAt: Date().timeIntervalSince1970
            )
            return context
        }

        let targetPath = try managedWorktreePath(repoRoot: sourceRoot, slug: slug(taskId ?? taskTitle ?? workspaceTitle))
        let branchExists = try await localBranchExists(branch, repositoryDirectory: sourceRoot)
        let arguments = branchExists
            ? ["worktree", "add", targetPath, branch]
            : ["worktree", "add", "-b", branch, targetPath, baseRef]
        do {
            _ = try await runGit(arguments, directory: sourceRoot)
        } catch WorkspaceGitContextError.commandFailed(_, let detail)
            where detail.localizedCaseInsensitiveContains("already checked out") {
            throw WorkspaceGitContextError.branchAlreadyCheckedOut(branch: branch, path: targetPath)
        }

        return try await inspectContext(
            directory: targetPath,
            repoRoot: sourceRoot,
            isManaged: true,
            taskTitle: taskTitle,
            taskId: taskId,
            externalURLString: externalURLString,
            baseRef: baseRef,
            createdAt: Date().timeIntervalSince1970
        )
    }

    static func attachContext(
        directory: String,
        taskTitle: String? = nil,
        taskId: String? = nil,
        externalURLString: String? = nil
    ) async throws -> WorkspaceGitContext {
        let root = try await repositoryRoot(for: directory)
        return try await inspectContext(
            directory: root,
            repoRoot: root,
            isManaged: false,
            taskTitle: taskTitle,
            taskId: taskId,
            externalURLString: externalURLString,
            baseRef: nil,
            createdAt: Date().timeIntervalSince1970
        )
    }

    static func refreshContext(_ context: WorkspaceGitContext) async throws -> WorkspaceGitContext {
        try await inspectContext(
            directory: context.activeDirectory,
            repoRoot: context.repoRoot,
            isManaged: context.isManaged,
            taskTitle: context.taskTitle,
            taskId: context.taskId,
            externalURLString: context.externalURLString,
            baseRef: context.baseRef,
            createdAt: context.createdAt
        )
    }

    private static func inspectContext(
        directory: String,
        repoRoot: String,
        isManaged: Bool,
        taskTitle: String?,
        taskId: String?,
        externalURLString: String?,
        baseRef: String?,
        createdAt: TimeInterval
    ) async throws -> WorkspaceGitContext {
        let activeRoot = try await repositoryRoot(for: directory)
        let branchOutput = try await runGit(["branch", "--show-current"], directory: activeRoot)
        let branch = normalized(branchOutput.stdout)
        let headOutput = try await runGit(["rev-parse", "HEAD"], directory: activeRoot)
        let statusOutput = try await runGit(["status", "--porcelain", "-uno"], directory: activeRoot)
        let detached = branch == nil
        return WorkspaceGitContext(
            repoRoot: repoRoot,
            worktreePath: activeRoot,
            baseRef: baseRef,
            branch: branch,
            headCommit: normalized(headOutput.stdout),
            isDetached: detached,
            isDirty: !statusOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isManaged: isManaged,
            taskTitle: normalized(taskTitle),
            taskId: normalized(taskId),
            externalURLString: normalized(externalURLString),
            createdAt: createdAt,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    private static func repositoryRoot(for directory: String) async throws -> String {
        let path = normalized(directory) ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            let result = try await runGit(["rev-parse", "--show-toplevel"], directory: path)
            guard let root = normalized(result.stdout) else {
                throw WorkspaceGitContextError.notGitRepository(path)
            }
            return root
        } catch WorkspaceGitContextError.commandFailed {
            throw WorkspaceGitContextError.notGitRepository(path)
        }
    }

    private static func localBranchExists(_ branch: String, repositoryDirectory: String) async throws -> Bool {
        do {
            _ = try await runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], directory: repositoryDirectory)
            return true
        } catch WorkspaceGitContextError.commandFailed(_, let detail) {
            if detail.isEmpty || detail.contains("exit 1") {
                return false
            }
            return false
        }
    }

    private static func listWorktrees(repositoryDirectory: String) async throws -> [WorktreeEntry] {
        let result = try await runGit(["worktree", "list", "--porcelain"], directory: repositoryDirectory)
        var entries: [WorktreeEntry] = []
        var currentPath: String?
        var currentBranch: String?
        var currentHead: String?
        var currentDetached = false

        func flush() {
            guard let path = currentPath else { return }
            entries.append(WorktreeEntry(path: path, branch: currentBranch, head: currentHead, detached: currentDetached))
            currentPath = nil
            currentBranch = nil
            currentHead = nil
            currentDetached = false
        }

        for line in result.stdout.components(separatedBy: .newlines) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush()
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                currentBranch = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                currentDetached = true
            }
        }
        flush()
        return entries
    }

    private static func managedWorktreePath(repoRoot: String, slug: String) throws -> String {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw WorkspaceGitContextError.worktreePathUnavailable
        }
        let repoHash = SHA256.hash(data: Data(repoRoot.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        let baseDirectory = appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(String(repoHash), isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        for suffix in [""] + (2...100).map({ "-\($0)" }) {
            let candidate = baseDirectory.appendingPathComponent(slug + suffix, isDirectory: true).path
            if !FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        throw WorkspaceGitContextError.worktreePathUnavailable
    }

    private static func managedRootContains(_ path: String, sourceRoot: String) -> Bool {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let managedRoot = appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .standardizedFileURL
            .path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(managedRoot + "/")
    }

    private static func normalizedBranch(_ ref: String?) -> String? {
        guard let ref = normalized(ref) else { return nil }
        if ref.hasPrefix("refs/heads/") {
            return String(ref.dropFirst("refs/heads/".count))
        }
        return ref
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let replaced = lowered.replacingOccurrences(
            of: "[^a-z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return trimmed.isEmpty ? "workspace" : String(trimmed.prefix(48))
    }

    private static func runGit(_ arguments: [String], directory: String) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git", "-C", directory] + arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: WorkspaceGitContextError.commandFailed(
                        command: "git \(arguments.joined(separator: " "))",
                        detail: error.localizedDescription
                    ))
                    return
                }

                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    let detail = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "exit \(process.terminationStatus)"
                        : err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: WorkspaceGitContextError.commandFailed(
                        command: "git \(arguments.joined(separator: " "))",
                        detail: detail
                    ))
                    return
                }
                continuation.resume(returning: CommandResult(stdout: out, stderr: err, status: process.terminationStatus))
            }
        }
    }
}
