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

/// Prints the scan as TSV. The fastest way to check detection without the UI.
func printList() {
    for entry in PortScanner().scan() {
        let pids = entry.pids.map(String.init).joined(separator: ",")
        let framework = entry.container == nil
            ? (entry.project?.frameworkLabel ?? entry.prettyCommand)
            : "Docker"
        let path = entry.displayPath ?? "-"

        print("\(entry.port)\t\(entry.state.rawValue)\t\(entry.kind.rawValue)\t\(framework)\t\(entry.title)\t\(pids)\t\(path)")
    }
}

let arguments = CommandLine.arguments

if arguments.contains("--list") {
    printList()
} else if arguments.contains("--login-status") {
    print(loginStatusText(SMAppService.mainApp.status))
} else if arguments.contains("--enable-login") {
    do {
        if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        }

        print(loginStatusText(SMAppService.mainApp.status))
    } catch {
        writeError("Failed to enable Open at Login: \(error.localizedDescription)")
        exit(1)
    }
} else if arguments.contains("--disable-login") {
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
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
