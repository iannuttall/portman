import AppKit
import Foundation

/// A terminal, editor or browser we can hand a path or URL to.
struct ExternalApp: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case terminal
        case editor
        case browser
    }

    let id: String
    let name: String
    let kind: Kind

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }
}

/// Opens projects and URLs in whichever apps the user actually has.
///
/// The previous version hardcoded Ghostty and VS Code. Everything here is now a
/// preference with a detected default, so the app is useful to someone running
/// iTerm and Zed without touching the source.
enum AppLauncher {
    // MARK: - Catalogue

    static let terminals: [ExternalApp] = [
        ExternalApp(id: "com.mitchellh.ghostty", name: "Ghostty", kind: .terminal),
        ExternalApp(id: "com.googlecode.iterm2", name: "iTerm", kind: .terminal),
        ExternalApp(id: "com.apple.Terminal", name: "Terminal", kind: .terminal),
        ExternalApp(id: "com.github.wez.wezterm", name: "WezTerm", kind: .terminal),
        ExternalApp(id: "dev.warp.Warp-Stable", name: "Warp", kind: .terminal),
        ExternalApp(id: "org.alacritty", name: "Alacritty", kind: .terminal),
        ExternalApp(id: "net.kovidgoyal.kitty", name: "kitty", kind: .terminal)
    ]

    static let editors: [ExternalApp] = [
        ExternalApp(id: "com.microsoft.VSCode", name: "VS Code", kind: .editor),
        ExternalApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", kind: .editor),
        ExternalApp(id: "dev.zed.Zed", name: "Zed", kind: .editor),
        ExternalApp(id: "com.sublimetext.4", name: "Sublime Text", kind: .editor),
        ExternalApp(id: "com.apple.dt.Xcode", name: "Xcode", kind: .editor)
    ]

    static func installed(_ kind: ExternalApp.Kind) -> [ExternalApp] {
        let catalogue: [ExternalApp]
        switch kind {
        case .terminal: catalogue = terminals
        case .editor: catalogue = editors
        case .browser: catalogue = installedBrowsers()
        }

        return catalogue.filter(\.isInstalled)
    }

    static func installedBrowsers() -> [ExternalApp] {
        let candidates = [
            ("com.apple.Safari", "Safari"),
            ("com.google.Chrome", "Chrome"),
            ("org.mozilla.firefox", "Firefox"),
            ("com.brave.Browser", "Brave"),
            ("com.microsoft.edgemac", "Edge"),
            ("company.thebrowser.Browser", "Arc")
        ]

        return candidates.map { ExternalApp(id: $0.0, name: $0.1, kind: .browser) }
    }

    // MARK: - Opening

    static func openInBrowser(_ url: URL, bundleID: String?) {
        guard
            let bundleID,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            NSWorkspace.shared.open(url)
            return
        }

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func openInEditor(path: String, bundleID: String?) {
        let target = bundleID ?? editors.first(where: \.isInstalled)?.id
        guard
            let target,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
        else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }

        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Terminals

    /// Opens a new terminal window at `path`.
    static func openTerminal(path: String, bundleID: String?) {
        let target = bundleID ?? terminals.first(where: \.isInstalled)?.id ?? "com.apple.Terminal"

        // Terminal.app and iTerm both treat a directory argument as "open here";
        // the others need their own working-directory flag.
        switch target {
        case "com.apple.Terminal", "com.googlecode.iterm2":
            run("/usr/bin/open", ["-b", target, path])
        case "com.mitchellh.ghostty":
            run("/usr/bin/open", ["-nb", target, "--args", "--working-directory=\(path)"])
        case "com.github.wez.wezterm":
            run("/usr/bin/open", ["-nb", target, "--args", "start", "--cwd", path])
        case "org.alacritty":
            run("/usr/bin/open", ["-nb", target, "--args", "--working-directory", path])
        case "net.kovidgoyal.kitty":
            run("/usr/bin/open", ["-nb", target, "--args", "--directory", path])
        default:
            run("/usr/bin/open", ["-b", target, path])
        }
    }

    /// Opens a terminal at `path` and runs `command` in it.
    ///
    /// Terminal.app and iTerm need AppleScript to run a command, which means the
    /// first use triggers an Automation permission prompt. Everything else takes
    /// an exec flag. Returns false when we couldn't drive the chosen terminal.
    @discardableResult
    static func runCommand(_ command: String, in path: String, bundleID: String?) -> Bool {
        let target = bundleID ?? terminals.first(where: \.isInstalled)?.id ?? "com.apple.Terminal"
        let shellCommand = "cd \(shellQuoted(path)) && \(command)"

        switch target {
        case "com.apple.Terminal":
            return runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(appleScriptQuoted(shellCommand))"
            end tell
            """)
        case "com.googlecode.iterm2":
            return runAppleScript("""
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(appleScriptQuoted(shellCommand))"
                end tell
            end tell
            """)
        case "com.mitchellh.ghostty":
            run("/usr/bin/open", [
                "-nb", target, "--args",
                "--working-directory=\(path)",
                "-e", "/bin/zsh", "-lc", "\(shellCommand); exec /bin/zsh"
            ])
            return true
        case "org.alacritty":
            run("/usr/bin/open", [
                "-nb", target, "--args",
                "--working-directory", path,
                "-e", "/bin/zsh", "-lc", "\(shellCommand); exec /bin/zsh"
            ])
            return true
        case "net.kovidgoyal.kitty":
            run("/usr/bin/open", [
                "-nb", target, "--args",
                "--directory", path,
                "/bin/zsh", "-lc", "\(shellCommand); exec /bin/zsh"
            ])
            return true
        case "com.github.wez.wezterm":
            run("/usr/bin/open", [
                "-nb", target, "--args",
                "start", "--cwd", path,
                "--", "/bin/zsh", "-lc", "\(shellCommand); exec /bin/zsh"
            ])
            return true
        default:
            openTerminal(path: path, bundleID: target)
            return false
        }
    }

    // MARK: - Dev servers

    /// The command that restarts a Node project, respecting its lockfile.
    /// Returns nil when there's no `dev` or `start` script to run.
    static func devCommand(for path: String) -> String? {
        let packageURL = URL(fileURLWithPath: path).appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: packageURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scripts = json["scripts"] as? [String: Any]
        else {
            return nil
        }

        let packageManager = packageManagerCommand(for: path)

        if scripts["dev"] is String {
            return packageManager == "npm" ? "npm run dev" : "\(packageManager) dev"
        }

        if scripts["start"] is String {
            return packageManager == "npm" ? "npm start" : "\(packageManager) start"
        }

        return nil
    }

    static func packageManagerCommand(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("bun.lock").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("bun.lockb").path) {
            return "bun"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }

        return "npm"
    }

    // MARK: - Network

    /// The LAN address, for the "copy network URL" action.
    static func localIPAddress() -> String? {
        for interface in ["en0", "en1"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            process.arguments = ["getifaddr", interface]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continue
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let address = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let address, !address.isEmpty {
                return address
            }
        }

        return nil
    }

    // MARK: - Primitives

    static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try? process.run()
    }

    @discardableResult
    static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
