import AppKit
import Darwin
import Foundation

/// A terminal emulator we know about.
struct TerminalApp: Sendable, Hashable, Identifiable {
    let name: String
    let bundleID: String
    /// Whether its scripting dictionary exposes the tty of a session. Without that there
    /// is no way to find the exact tab a process is running in, only the app.
    let supportsTTYAttach: Bool

    var id: String { bundleID }
}

/// "Jump to the terminal window this server is running in."
///
/// Worth knowing before reading further: most long-running dev servers on this machine
/// have *no* controlling terminal. The shell that launched them has exited, so they sit
/// reparented to launchd with `tty = ??`. That is the common path here, not an edge case,
/// and it is handled by returning nil/false immediately — no subprocess, no Apple event,
/// no prompt — so the caller can offer "open a new terminal at the project root" instead.
///
/// The AppleScript path needs `NSAppleEventsUsageDescription` in Info.plist. Without it
/// macOS terminates the app instead of showing the Automation prompt.
enum TerminalAttach {
    /// Ordered so the two terminals that can actually pinpoint a tab are tried first.
    static let knownTerminals: [TerminalApp] = [
        TerminalApp(name: "iTerm", bundleID: "com.googlecode.iterm2", supportsTTYAttach: true),
        TerminalApp(name: "Terminal", bundleID: "com.apple.Terminal", supportsTTYAttach: true),
        TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty", supportsTTYAttach: false),
        TerminalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm", supportsTTYAttach: false),
        TerminalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable", supportsTTYAttach: false),
        TerminalApp(name: "Alacritty", bundleID: "org.alacritty", supportsTTYAttach: false),
        TerminalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty", supportsTTYAttach: false)
    ]

    /// Which terminal apps are installed, so the UI only offers real choices.
    static func installedTerminals() -> [TerminalApp] {
        knownTerminals.filter { isInstalled($0) }
    }

    static func isInstalled(_ terminal: TerminalApp) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) != nil
    }

    // MARK: - Controlling terminal

    /// e.g. "/dev/ttys004", or nil when the process has no controlling terminal.
    static func tty(forPID pid: Int32) -> String? {
        guard let info = processInfo(forPID: pid) else { return nil }
        return ttyPath(forDevice: info.terminalDevice)
    }

    /// `e_tdev` is a `dev_t` widened to unsigned. NODEV (-1) means no controlling terminal.
    /// `devname` does the device-number lookup properly; the minor-number fallback covers
    /// the case where the entry has already been reclaimed.
    static func ttyPath(forDevice device: UInt32) -> String? {
        guard device != UInt32.max else { return nil }

        var name = String(format: "ttys%03d", Int(device & 0xff_ffff))

        if let resolved = devname(dev_t(bitPattern: device), S_IFCHR) {
            let looked = String(cString: resolved)
            // devname reports "??" when it can't resolve the number.
            if !looked.isEmpty && looked != "??" {
                name = looked
            }
        }

        let path = "/dev/\(name)"
        guard access(path, F_OK) == 0 else { return nil }

        return path
    }

    // MARK: - Focus

    /// Focuses the terminal tab/window owning that tty. Returns false when it couldn't —
    /// including the common no-tty case, and the case where the owning terminal simply
    /// has no way to tell us which tab is which.
    @MainActor
    static func focusTerminal(forPID pid: Int32) async -> Bool {
        guard let tty = tty(forPID: pid), isSafeTTYPath(tty) else {
            return false
        }

        for terminal in knownTerminals where terminal.supportsTTYAttach {
            // Addressing an app that isn't running would launch it, which is not what
            // "jump to the window it's running in" should ever do.
            guard isRunning(terminal), isInstalled(terminal) else { continue }
            if focus(tty: tty, in: terminal) { return true }
        }

        // Ghostty, WezTerm, Warp, Alacritty and kitty don't publish a session's tty, so the
        // most we can honestly do is bring the owning app forward and report failure.
        if let owner = owningTerminal(forPID: pid) {
            activate(owner)
        }

        return false
    }

    @MainActor
    static func isRunning(_ terminal: TerminalApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleID).isEmpty
    }

    @MainActor
    static func activate(_ terminal: TerminalApp) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleID)
        running.first?.activate()
    }

    /// Walks the parent chain looking for a process inside a known terminal's app bundle.
    /// Only ever finds something while the launching shell is still alive; a reparented
    /// server has ppid 1 and this gives up on the first hop.
    static func owningTerminal(forPID pid: Int32) -> TerminalApp? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 12 {
            if let terminal = terminalOwning(pid: current) {
                return terminal
            }

            guard let parent = parentPID(of: current), parent != current else {
                return nil
            }

            current = parent
            depth += 1
        }

        return nil
    }

    // MARK: - AppleScript

    private static let successMarker = "focused"

    @MainActor
    private static func focus(tty: String, in terminal: TerminalApp) -> Bool {
        guard
            let source = script(for: terminal, tty: tty),
            let script = NSAppleScript(source: source)
        else {
            return false
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        // -1743 is "not authorised to send Apple events", i.e. the user denied the
        // Automation prompt. The rest is the target app being busy, quitting, or running an
        // older scripting dictionary. None of it changes what we do: the caller falls back
        // to opening a fresh terminal either way.
        guard errorInfo == nil else { return false }

        return result.stringValue == successMarker
    }

    /// Both dictionaries expose `tty` per session; everything else is walking the
    /// window/tab/session tree. `with timeout` bounds the wait, since the Apple event is
    /// sent from the main thread and a wedged terminal would otherwise hold it.
    static func script(for terminal: TerminalApp, tty: String) -> String? {
        switch terminal.bundleID {
        case "com.apple.Terminal":
            return """
            with timeout of 2 seconds
                tell application id "com.apple.Terminal"
                    repeat with theWindow in windows
                        repeat with theTab in tabs of theWindow
                            if tty of theTab is "\(tty)" then
                                set selected of theTab to true
                                set index of theWindow to 1
                                activate
                                return "\(successMarker)"
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            return "none"
            """

        case "com.googlecode.iterm2":
            return """
            with timeout of 2 seconds
                tell application id "com.googlecode.iterm2"
                    repeat with theWindow in windows
                        repeat with theTab in tabs of theWindow
                            repeat with theSession in sessions of theTab
                                if tty of theSession is "\(tty)" then
                                    select theWindow
                                    select theTab
                                    select theSession
                                    activate
                                    return "\(successMarker)"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end timeout
            return "none"
            """

        default:
            return nil
        }
    }

    /// The tty comes from `devname`, but it is interpolated into a script literal, so it
    /// gets checked rather than trusted.
    static func isSafeTTYPath(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/"), path.count <= 64 else { return false }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - libproc

    /// The two facts we need about a process.
    struct BSDProcessInfo: Sendable, Hashable {
        let terminalDevice: UInt32
        let parentPID: Int32
    }

    /// `proc_pidinfo` is the cheaper call, but the kernel refuses it for processes owned by
    /// root — and `login` is root, sitting between every terminal app and the shell it
    /// spawned. Without the sysctl fallback the parent walk stops dead one hop up.
    static func processInfo(forPID pid: Int32) -> BSDProcessInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)

        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return BSDProcessInfo(
                terminalDevice: info.e_tdev,
                parentPID: Int32(bitPattern: info.pbi_ppid)
            )
        }

        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kernelInfo = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride

        // A dead pid answers with success and a zero-length result, not an error.
        guard sysctl(&name, UInt32(name.count), &kernelInfo, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        return BSDProcessInfo(
            terminalDevice: UInt32(bitPattern: kernelInfo.kp_eproc.e_tdev),
            parentPID: kernelInfo.kp_eproc.e_ppid
        )
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        processInfo(forPID: pid)?.parentPID
    }

    private static func terminalOwning(pid: Int32) -> TerminalApp? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }

        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        guard let bundleID = bundleIdentifier(forExecutablePath: path) else {
            return nil
        }

        return knownTerminals.first { $0.bundleID == bundleID }
    }

    private static func bundleIdentifier(forExecutablePath path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        var depth = 0

        while depth < 6 {
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                return nil
            }

            url = parent
            depth += 1
        }

        return nil
    }
}
