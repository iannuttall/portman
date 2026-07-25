import Darwin
import Foundation

/// Walks the process tree through `proc_bsdinfo.pbi_ppid` to answer "did a human start
/// this from a shell, terminal, editor or coding agent?".
///
/// Deliberately only a *positive* signal. A dev server that has outlived the shell that
/// launched it gets reparented to launchd, so it reports `ppid == 1` with no trace of its
/// origin — and on this machine that is the common case for anything long-running.
/// `isDeveloperLaunched` returns false for those, so callers must combine it with other
/// evidence (a project root on disk, the command line, the working directory) rather than
/// treating it as the only gate. The raw helpers are exposed for exactly that.
enum ProcessAncestry {
    /// Enough to cross `launchd → terminal → shell → npm → node → esbuild` and then some,
    /// while still bounding the syscall cost of a scan that touches every listener.
    static let maxDepth = 12

    static func parentPID(of pid: Int32) -> Int32? {
        guard pid > 1, let info = bsdInfo(pid) else { return nil }

        let parent = Int32(bitPattern: info.pbi_ppid)
        return parent > 0 ? parent : nil
    }

    /// The kernel's short name for the process — `node`, `zsh`, `Code Helper`.
    static func name(of pid: Int32) -> String? {
        guard let info = bsdInfo(pid) else { return nil }

        let long = string(from: info.pbi_name)
        if !long.isEmpty {
            return long
        }

        // `pbi_name` is empty for some processes; `pbi_comm` is truncated but always set.
        let short = string(from: info.pbi_comm)
        return short.isEmpty ? nil : short
    }

    /// Full executable path. Fails for other users' processes, which is expected.
    static func path(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(pathBufferSize))

        guard length > 0 else { return nil }

        // proc_pidpath returns the path length, so slice rather than scan for the null.
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The parent chain above `pid`, nearest first. Stops at launchd, at `maxDepth`, or as
    /// soon as a pid repeats — a recycled pid could otherwise close the chain into a loop.
    static func ancestors(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var seen: Set<Int32> = [pid]
        var current = pid

        while chain.count < maxDepth, let parent = parentPID(of: current), parent > 1 {
            if seen.contains(parent) { break }

            chain.append(parent)
            seen.insert(parent)
            current = parent
        }

        return chain
    }

    /// True when any ancestor is a shell, terminal, editor or coding agent.
    static func isDeveloperLaunched(pid: Int32) -> Bool {
        ancestors(of: pid).contains { isDeveloperTool(name: name(of: $0), path: path(of: $0)) }
    }

    // MARK: - libproc

    /// `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift can't import, so spell out its value:
    /// `4 * MAXPATHLEN`, the buffer size `proc_pidpath` documents.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// Reads one of libproc's fixed-size C char arrays, which Swift imports as a tuple.
    /// Stops at the first null and never runs past the field, since a name that fills the
    /// field exactly is not terminated.
    private static func string<Field>(from field: Field) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)

        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }

        return info
    }

    // MARK: - Matching

    /// Matches on the executable's own name first, then on any path component — an agent
    /// running as `/Users/x/.bun/bin/opencode` and one running as a plain `node` under
    /// `/Applications/Cursor.app/…` both need to resolve.
    static func isDeveloperTool(name: String?, path: String?) -> Bool {
        if let name, matchesName(name) { return true }

        guard let path else { return false }

        let lower = path.lowercased()
        if matchesName(URL(fileURLWithPath: lower).lastPathComponent) { return true }

        // Only as an app bundle, never as a bare token anywhere in the path. `zed`,
        // `warp`, `kitty`, `goose` and `roo` are ordinary words — matching them loosely
        // promotes anything living under ~/dev/zed-experiments into a trusted tool.
        if pathTokens.contains(where: { lower.contains("/\($0).app/") }) { return true }

        return pathPhrases.contains { lower.contains($0) }
    }

    private static func matchesName(_ name: String) -> Bool {
        let lower = name.lowercased()

        if executableNames.contains(lower) { return true }
        // `Code Helper (Plugin)`, `claude-code`, `gemini-cli` — take the leading word too.
        if let head = lower.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).first,
           executableNames.contains(String(head)) {
            return true
        }

        return namePhrases.contains { lower.contains($0) }
    }

    // MARK: - Tables

    /// Exact executable basenames. Kept strict: these are short, common words, and a
    /// substring match on `nu` or `roo` would fire on half the filesystem.
    private static let executableNames: Set<String> = [
        // Shells and multiplexers
        "sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh", "dash", "nu", "pwsh",
        "tmux", "screen", "login",
        // Coding agents
        "claude", "codex", "aider", "conductor", "opencode", "goose", "continue",
        "cline", "roo", "gemini", "openhands", "qodo", "cursor", "zed", "code"
    ]

    /// Substrings that only appear in a developer tool's own name.
    private static let namePhrases = [
        "terminal", "iterm", "ghostty", "wezterm", "warp", "alacritty", "kitty", "hyper",
        "code helper", "visual studio code", "cursor helper", "xcode", "jetbrains",
        "intellij", "webstorm", "pycharm", "goland", "rubymine", "clion", "android studio",
        "claude", "codex", "aider", "conductor", "opencode", "openhands", "gemini-cli"
    ]

    /// Path components that identify the launching app, matched as whole tokens so
    /// `/Applications/Cursor.app/Contents/MacOS/node` resolves through its bundle.
    private static let pathTokens: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "wezterm", "warp", "alacritty", "kitty",
        "hyper", "cursor", "zed", "xcode", "jetbrains", "intellij", "webstorm", "pycharm",
        "goland", "rubymine", "clion", "conductor", "claude", "codex", "aider", "cline",
        "roo", "goose", "opencode", "openhands", "qodo", "tmux"
    ]

    /// Multi-word or punctuated forms a token split would break apart.
    private static let pathPhrases = [
        "visual studio code",
        "code helper",
        "android studio",
        "gemini-cli",
        "continue.dev",
        "/.vscode/",
        "/.cursor/",
        "/.claude/",
        "/.codex/"
    ]
}
