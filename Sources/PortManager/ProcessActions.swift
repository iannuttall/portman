import AppKit
import Darwin
import Foundation
import ServiceManagement

extension PortManagerApp {
    @objc func pinItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var keys = pinnedKeys
        keys.insert(key)
        pinnedKeys = keys
        rebuildMenu()
    }

    @objc func openInGhostty(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        launchProcess(
            executable: "/usr/bin/open",
            arguments: ["-na", "Ghostty", "--args", "--working-directory=\(path)"]
        )
    }

    @objc func openInVSCode(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }

        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/code") {
            launchProcess(executable: "/usr/local/bin/code", arguments: [path])
        } else {
            launchProcess(executable: "/usr/bin/open", arguments: ["-a", "Visual Studio Code", path])
        }
    }

    @objc func restartDevServer(_ sender: NSMenuItem) {
        guard
            let target = sender.representedObject as? RestartTarget,
            let command = devCommand(for: target.path)
        else {
            return
        }

        for pid in target.pids {
            Darwin.kill(pid, SIGTERM)
        }

        let shellCommand = "cd \(shellQuoted(target.path)) && \(command); exec /bin/zsh"
        launchProcess(
            executable: "/usr/bin/open",
            arguments: [
                "-na",
                "Ghostty",
                "--args",
                "--working-directory=\(target.path)",
                "-e",
                "/bin/zsh",
                "-lc",
                shellCommand
            ]
        )

        requestRefresh(force: true)
    }

    @objc func unpinItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var keys = pinnedKeys
        keys.remove(key)
        pinnedKeys = keys
        rebuildMenu()
    }

    @objc func ignoreItem(_ sender: NSMenuItem) {
        guard
            let payload = sender.representedObject as? String,
            let separator = payload.firstIndex(of: ":")
        else {
            return
        }

        let kind = String(payload[..<separator])
        let value = String(payload[payload.index(after: separator)...])

        switch kind {
        case "port":
            if let port = Int(value) {
                var ports = ignoredPorts
                ports.insert(port)
                ignoredPorts = ports
            }
        case "command":
            var commands = ignoredCommands
            commands.insert(value)
            ignoredCommands = commands
        case "target":
            var targets = ignoredTargets
            targets.insert(value)
            ignoredTargets = targets
        default:
            break
        }

        rebuildMenu()
    }

    @objc func openInBrowser(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ListeningProcess else { return }
        NSWorkspace.shared.open(localURL(for: process))
    }

    @objc func copyLocalURL(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ListeningProcess else { return }
        copyToPasteboard(localURL(for: process).absoluteString)
    }

    @objc func copyNetworkURL(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let address = networkAddress
        else {
            return
        }

        copyToPasteboard("http://\(address):\(process.port)")
    }

    @objc func copyProjectPath(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.project?.root ?? process.project?.cwd
        else {
            return
        }

        copyToPasteboard(path)
    }

    @objc func revealProject(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.project?.root ?? process.project?.cwd
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func copyContainerProjectPath(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.container?.workingDirectory
        else {
            return
        }

        copyToPasteboard(path)
    }

    @objc func revealContainerProject(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.container?.workingDirectory
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func copyContainerName(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let name = process.container?.name
        else {
            return
        }

        copyToPasteboard(name)
    }

    @objc func copyGroupProjectPath(_ sender: NSMenuItem) {
        guard
            let group = sender.representedObject as? ProcessGroup,
            let path = group.project?.root ?? group.project?.cwd
        else {
            return
        }

        copyToPasteboard(path)
    }

    @objc func revealGroupProject(_ sender: NSMenuItem) {
        guard
            let group = sender.representedObject as? ProcessGroup,
            let path = group.project?.root ?? group.project?.cwd
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func killProcess(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ListeningProcess else { return }

        for pid in process.pids {
            Darwin.kill(pid, SIGTERM)
        }

        requestRefresh(force: true)
    }

    @objc func killProcessGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? ProcessGroup else { return }

        for pid in group.pids {
            Darwin.kill(pid, SIGTERM)
        }

        requestRefresh(force: true)
    }

    @objc func stopContainer(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let container = process.container
        else {
            return
        }

        stopContainers(ids: [container.id])
    }

    @objc func stopContainerGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? ProcessGroup else { return }
        stopContainers(ids: group.dockerContainers.map(\.id))
    }

    func stopContainers(ids: [String]) {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard !uniqueIDs.isEmpty else { return }

        Task { [weak self] in
            await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
                process.arguments = ["stop"] + uniqueIDs

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    _ = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                } catch {
                    return
                }
            }.value

            self?.requestRefresh(force: true)
        }
    }

    @objc func toggleShowAllProcesses(_ sender: NSMenuItem) {
        showAllProcesses.toggle()
        rebuildMenu()
    }

    @objc func refreshNow() {
        requestRefresh(force: true)
    }

    @objc func toggleOpenAtLogin(_ sender: NSMenuItem) {
        do {
            if openAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(
                title: "Open at Login Unavailable",
                message: "Open at Login only works when Port Manager is running from a signed app bundle."
            )
        }

        rebuildMenu()
    }

    @objc func showAbout() {
        let panel = NSAlert()
        panel.messageText = "Port Manager"
        panel.informativeText = "A small menu bar app for finding and killing local listening ports."
        panel.alertStyle = .informational
        panel.addButton(withTitle: "OK")
        panel.runModal()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    var openAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func localURL(for process: ListeningProcess) -> URL {
        URL(string: "http://localhost:\(process.port)")!
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func devCommand(for path: String) -> String? {
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

    func packageManagerCommand(for path: String) -> String {
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

    func launchProcess(executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return
        }
    }

    func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated static func localIPAddressValue() -> String? {
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

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
