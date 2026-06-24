import AppKit
import Foundation
import ServiceManagement

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func loginStatusText(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled:
        return "enabled"
    case .notRegistered:
        return "not-registered"
    case .notFound:
        return "not-found"
    case .requiresApproval:
        return "requires-approval"
    @unknown default:
        return "unknown"
    }
}

if CommandLine.arguments.contains("--list") {
    for process in PortScanner().listeningProcesses() {
        let pids = process.pids.map(String.init).joined(separator: ",")
        let framework = process.container == nil
            ? (process.project?.framework ?? process.prettyCommand)
            : "Docker"
        let project = process.container?.displayName ?? process.project?.name ?? "-"
        let path = process.container?.displayPath ?? process.project?.displayPath ?? "-"
        let state = process.project?.isStaleWorktree == true
            ? "stale-worktree"
            : (process.project?.isOrphan == true ? "orphan" : "active")
        print("\(process.port)\t\(state)\t\(framework)\t\(project)\t\(pids)\t\(path)")
    }
} else if CommandLine.arguments.contains("--login-status") {
    print(loginStatusText(SMAppService.mainApp.status))
} else if CommandLine.arguments.contains("--enable-login") {
    do {
        if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        }

        print(loginStatusText(SMAppService.mainApp.status))
    } catch {
        writeError("Failed to enable Open at Login: \(error.localizedDescription)")
        exit(1)
    }
} else if CommandLine.arguments.contains("--disable-login") {
    do {
        if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }

        print(loginStatusText(SMAppService.mainApp.status))
    } catch {
        writeError("Failed to disable Open at Login: \(error.localizedDescription)")
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = PortManagerApp()
    app.delegate = delegate
    app.run()
}
