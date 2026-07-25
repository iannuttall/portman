import Darwin
import Foundation

/// Reads the git state of a project root.
///
/// This runs for every detected project on every scan, so the common path spawns nothing:
/// branch, detached-head and linked-worktree state all come from reading `.git` off disk.
/// Only the dirty count needs `git status`, and that is skipped while the git dir's `index`
/// and `HEAD` have not moved since the last reading.
///
/// Nothing here throws or traps. The app deliberately tracks projects whose directories
/// have been deleted out from under a running process, so half-written and half-deleted
/// `.git` entries are expected input, not a corner case.
actor GitInspector {
    /// Where the real git dir lives for a root, and how we got there.
    struct GitLocation: Sendable, Hashable {
        /// The directory that holds `.git` — what `git -C` should be pointed at.
        let workingRoot: String
        /// The directory holding `HEAD` and `index`. For a linked worktree this is
        /// `<main repo>/.git/worktrees/<name>`, not the main repo's `.git`.
        let gitDir: String
        let isWorktree: Bool
    }

    /// What `HEAD` says: either a branch, or a short object name for a detached head.
    struct HeadRef: Sendable, Hashable {
        let branch: String?
        let isDetached: Bool
    }

    /// The mtimes git rewrites when the working tree, the index or HEAD changes.
    private struct Fingerprint: Equatable {
        let index: TimeSpec?
        let head: TimeSpec?
    }

    private struct TimeSpec: Equatable {
        let seconds: Int
        let nanoseconds: Int
    }

    private struct CacheEntry {
        let fingerprint: Fingerprint
        let dirtyCount: Int?
        let readAt: Date
    }

    /// Longest `git status` gets before we give up on the dirty count. A repo on a stalled
    /// network mount must not hold up a scan; the branch is reported without it.
    private static let statusTimeout: TimeInterval = 2

    /// Editing a file does not touch `.git/index`, so the fingerprint alone would let a
    /// dirty count go stale indefinitely. Re-reading at most once a minute per root keeps
    /// it honest while still collapsing the every-few-seconds scan cadence to nothing.
    private static let dirtyMaxAge: TimeInterval = 60

    private var cache: [String: CacheEntry] = [:]

    func status(forRoot root: String) -> GitStatus? {
        guard
            let location = Self.locateGitDir(startingAt: root),
            let head = Self.readHead(inGitDir: location.gitDir)
        else {
            cache[root] = nil
            return nil
        }

        var status = GitStatus(
            branch: head.branch,
            dirtyCount: nil,
            isWorktree: location.isWorktree,
            isDetached: head.isDetached
        )

        let fingerprint = Self.fingerprint(forGitDir: location.gitDir)
        let now = Date()

        if
            let cached = cache[root],
            cached.fingerprint == fingerprint,
            now.timeIntervalSince(cached.readAt) < Self.dirtyMaxAge
        {
            status.dirtyCount = cached.dirtyCount
            return status
        }

        let dirtyCount = Self.dirtyCount(atRoot: location.workingRoot, timeout: Self.statusTimeout)
        cache[root] = CacheEntry(fingerprint: fingerprint, dirtyCount: dirtyCount, readAt: now)
        status.dirtyCount = dirtyCount

        return status
    }

    /// Forgets every cached dirty count, so the next call re-runs `git status` per root.
    func reset() {
        cache.removeAll()
    }

    // MARK: - Locating the git dir

    /// Walks ancestors the way git itself does, so a package inside a monorepo still
    /// reports the repo it belongs to. Bounded, and every step is a single `stat`.
    static func locateGitDir(startingAt path: String) -> GitLocation? {
        var current = path
        var depth = 0

        while true {
            let dotGit = "\(current)/.git"
            var info = stat()

            if stat(dotGit, &info) == 0 {
                let type = info.st_mode & S_IFMT

                if type == S_IFDIR {
                    return GitLocation(workingRoot: current, gitDir: dotGit, isWorktree: false)
                }

                // A `.git` file instead of a directory means a linked worktree: the real
                // git dir lives under the main repo and is named in a `gitdir:` line.
                if
                    type == S_IFREG,
                    let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
                    let gitDir = parseGitdirFile(contents, relativeTo: current),
                    access(gitDir, F_OK) == 0
                {
                    return GitLocation(workingRoot: current, gitDir: gitDir, isWorktree: true)
                }

                return nil
            }

            let next = URL(fileURLWithPath: current).deletingLastPathComponent().path
            depth += 1

            if next == current || next == "/" || depth >= 8 {
                return nil
            }

            current = next
        }
    }

    static func readHead(inGitDir gitDir: String) -> HeadRef? {
        guard let contents = try? String(contentsOfFile: "\(gitDir)/HEAD", encoding: .utf8) else {
            return nil
        }

        return parseHEAD(contents)
    }

    // MARK: - Parsing

    static func parseHEAD(_ contents: String) -> HeadRef? {
        guard let firstLine = contents.split(whereSeparator: \.isNewline).first else {
            return nil
        }

        let line = firstLine.trimmingCharacters(in: .whitespaces)

        if line.hasPrefix("ref: ") {
            let ref = line.dropFirst("ref: ".count).trimmingCharacters(in: .whitespaces)
            let branch = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count))
                : ref

            guard !branch.isEmpty else { return nil }
            return HeadRef(branch: branch, isDetached: false)
        }

        // A bare object name in HEAD is a detached head. The short form is all a row shows.
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else {
            return nil
        }

        return HeadRef(branch: String(line.prefix(7)), isDetached: true)
    }

    /// `gitdir:` may be absolute or relative to the worktree it was found in.
    static func parseGitdirFile(_ contents: String, relativeTo root: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("gitdir:") else { continue }

            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }

            let absolute = path.hasPrefix("/") ? path : "\(root)/\(path)"
            return URL(fileURLWithPath: absolute).standardizedFileURL.path
        }

        return nil
    }

    static func countPorcelainLines(_ output: String) -> Int {
        output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    // MARK: - Change detection

    private static func fingerprint(forGitDir gitDir: String) -> Fingerprint {
        Fingerprint(
            index: modificationTime(at: "\(gitDir)/index"),
            head: modificationTime(at: "\(gitDir)/HEAD")
        )
    }

    private static func modificationTime(at path: String) -> TimeSpec? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }

        return TimeSpec(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    // MARK: - git status

    private static let gitExecutable = "/usr/bin/git"

    static func dirtyCount(atRoot root: String, timeout: TimeInterval) -> Int? {
        // `--no-optional-locks` stops a background poll from taking the index lock or
        // rewriting the index under a git command the user is running in a terminal.
        let output = runGit(
            arguments: ["--no-optional-locks", "-C", root, "status", "--porcelain"],
            timeout: timeout
        )

        return output.map(countPorcelainLines)
    }

    /// Collected on a reader thread so the deadline below is real, and so a repo with more
    /// output than the pipe buffer holds can't wedge git waiting for us to drain it.
    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// Runs `/usr/bin/git` directly — no shell — and returns nil on failure or timeout.
    static func runGit(arguments: [String], timeout: TimeInterval) -> String? {
        guard access(gitExecutable, X_OK) == 0 else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let buffer = OutputBuffer()
        let finished = DispatchSemaphore(value: 0)
        let descriptor = pipe.fileHandleForReading.fileDescriptor

        DispatchQueue.global(qos: .utility).async {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                let count = chunk.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                }

                if count > 0 {
                    buffer.data.append(contentsOf: chunk[0..<count])
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }

            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Killing git closes the write end, which is what lets the reader thread
            // finish; waiting for it keeps the pipe alive until nothing is using it.
            process.terminate()

            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                let pid = process.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }

                finished.wait()
            }

            process.waitUntilExit()
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: buffer.data, encoding: .utf8)
    }
}
