import Foundation


struct ListeningProcess: Hashable, Sendable {
    let pids: [Int32]
    let command: String
    let user: String
    let port: Int
    let addresses: [String]
    let project: ProjectMetadata?
    let container: DockerContainer?

    var displayName: String {
        if let container {
            if let containerPort = container.containerPort {
                return "\(port) -> \(containerPort) · \(container.displayName)"
            }

            return "\(port) · \(container.displayName)"
        }

        if let project {
            if project.isStaleWorktree {
                return "\(port) · Stale Worktree · \(project.framework ?? prettyCommand) · \(project.name)"
            }

            if project.isOrphan {
                return "\(port) · Orphan · \(project.framework ?? prettyCommand) · \(project.name)"
            }

            return "\(port) · \(project.framework ?? prettyCommand) · \(project.name)"
        }

        return "\(port) · \(prettyCommand)"
    }

    var groupName: String {
        if let container {
            return "Docker · \(container.groupName)"
        }

        if let project {
            if project.isStaleWorktree {
                return "Stale Worktrees"
            }

            if project.isOrphan {
                return "Orphan Processes"
            }

            return "\(project.framework ?? prettyCommand) · \(project.name)"
        }

        return prettyCommand
    }

    var pinKey: String {
        if let container {
            return "docker:\(container.composeProject ?? ""):\(container.composeService ?? ""):\(container.name)"
        }

        if let project {
            return "project:\(project.root ?? project.cwd ?? project.name)"
        }

        return "process:\(command):\(port)"
    }

    var pinTitle: String {
        if container != nil {
            return "Pin Container"
        }

        if project != nil {
            return "Pin Project"
        }

        return "Pin Port"
    }

    var unpinTitle: String {
        if container != nil {
            return "Unpin Container"
        }

        if project != nil {
            return "Unpin Project"
        }

        return "Unpin Port"
    }

    var ignoreTargetKey: String? {
        if let container {
            return (container.composeProject.map { "\($0)/\(container.composeService ?? container.name)" } ?? container.name)
                .lowercased()
        }

        if let project {
            return (project.root ?? project.cwd ?? project.name).lowercased()
        }

        return nil
    }

    var prettyCommand: String {
        let lower = command.lowercased()

        if lower == "node" {
            return "Node"
        }

        if lower.contains("python") {
            return "Python"
        }

        if lower.contains("httpd") {
            return "httpd"
        }

        if lower.contains("nginx") {
            return "nginx"
        }

        if lower.contains("postgres") {
            return "Postgres"
        }

        if lower.contains("redis") {
            return "Redis"
        }

        return command.prefix(1).uppercased() + command.dropFirst()
    }

    var primaryPID: Int32? {
        pids.sorted().first
    }

    var isLikelyHelperPort: Bool {
        if port >= 9229 && port <= 9329 {
            return true
        }

        if port >= 49152 {
            return true
        }

        return false
    }

    var killTitle: String {
        if let container {
            return "Stop Container (\(container.name))"
        }

        if pids.count == 1, let primaryPID {
            return "Kill Process (id \(primaryPID))"
        }

        return "Kill Processes (\(pids.count) ids)"
    }

    var hiddenByDefault: Bool {
        if container != nil {
            return false
        }

        if project?.isOrphan == true {
            return false
        }

        if port < 1024 {
            return true
        }

        let lower = command.lowercased()
        return [
            "controlcenter",
            "rapportd",
            "raycast",
            "ollama"
        ].contains(lower)
    }
}

struct DockerContainer: Hashable, Sendable {
    let id: String
    let name: String
    let image: String
    let composeProject: String?
    let composeService: String?
    let workingDirectory: String?
    let hostPort: Int
    let containerPort: Int?

    var displayName: String {
        if let composeProject, let composeService {
            return "\(composeProject)/\(composeService)"
        }

        return name
    }

    var groupName: String {
        displayName
    }

    var displayPath: String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return workingDirectory.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~",
            options: [.anchored]
        )
    }
}

struct ProcessSnapshot: Sendable {
    var pid: Int32 = 0
    var command = ""
    var user = ""
    var ports: [Int: Set<String>] = [:]
}

struct ProjectMetadata: Hashable, Sendable {
    let cwd: String?
    let root: String?
    let name: String
    let framework: String?
    let isOrphan: Bool
    let isStaleWorktree: Bool

    var displayPath: String? {
        guard let path = root ?? cwd else { return nil }
        return path.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~",
            options: [.anchored]
        )
    }
}

struct ProcessGroup {
    let name: String
    let processes: [ListeningProcess]

    var sortedProcesses: [ListeningProcess] {
        processes.sorted {
            if $0.port == $1.port {
                return ($0.primaryPID ?? 0) < ($1.primaryPID ?? 0)
            }

            return $0.port < $1.port
        }
    }

    var pids: [Int32] {
        Array(Set(processes.flatMap(\.pids))).sorted()
    }

    var project: ProjectMetadata? {
        let projects = Set(processes.compactMap(\.project))
        return projects.count == 1 ? projects.first : nil
    }

    var allOrphans: Bool {
        !processes.isEmpty && processes.allSatisfy { $0.project?.isOrphan == true }
    }

    var allStaleWorktrees: Bool {
        !processes.isEmpty && processes.allSatisfy { $0.project?.isStaleWorktree == true }
    }

    var dockerContainers: [DockerContainer] {
        Array(Set(processes.compactMap(\.container))).sorted {
            if $0.displayName == $1.displayName {
                return $0.hostPort < $1.hostPort
            }

            return $0.displayName < $1.displayName
        }
    }

    var allDocker: Bool {
        !processes.isEmpty && processes.allSatisfy { $0.container != nil }
    }

    var primaryProcess: ListeningProcess? {
        sortedProcesses.first { !$0.isLikelyHelperPort } ?? sortedProcesses.first
    }

    var pinKey: String? {
        let keys = Set(processes.map(\.pinKey))
        return keys.count == 1 ? keys.first : nil
    }

    var pinTitle: String {
        if allDocker {
            return "Pin Container"
        }

        if project != nil {
            return "Pin Project"
        }

        return "Pin Group"
    }

    var unpinTitle: String {
        if allDocker {
            return "Unpin Container"
        }

        if project != nil {
            return "Unpin Project"
        }

        return "Unpin Group"
    }

    var killTitle: String {
        let count = pids.count
        if count == 1, let pid = pids.first {
            return "Kill All Processes (id \(pid))"
        }

        return "Kill All Processes (\(count) ids)"
    }
}

final class RestartTarget: NSObject {
    let path: String
    let pids: [Int32]

    init(path: String, pids: [Int32]) {
        self.path = path
        self.pids = pids
    }
}
