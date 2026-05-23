import AppKit
import Foundation

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
} else {
    let app = NSApplication.shared
    let delegate = PortManagerApp()
    app.delegate = delegate
    app.run()
}
