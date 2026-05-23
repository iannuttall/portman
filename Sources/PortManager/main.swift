import AppKit
import Darwin
import Foundation
import ServiceManagement

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

final class PortScanner {
    func listeningProcesses() -> [ListeningProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        var snapshots: [ProcessSnapshot] = []
        var current: ProcessSnapshot?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                if let current, current.pid > 0 {
                    snapshots.append(current)
                }

                current = ProcessSnapshot(pid: Int32(value) ?? 0)
            case "c":
                current?.command = value
            case "L":
                current?.user = value
            case "n":
                guard let port = Self.port(from: value) else { continue }
                let address = Self.address(from: value)
                current?.ports[port, default: []].insert(address)
            default:
                continue
            }
        }

        if let current, current.pid > 0 {
            snapshots.append(current)
        }

        let metadataByPID = Self.metadataByPID(for: snapshots)
        let dockerContainersByHostPort = snapshots.contains {
            $0.command.lowercased() == "com.docker.backend"
        } ? Self.dockerContainersByHostPort() : [:]

        let rawProcesses = snapshots.flatMap { snapshot in
            snapshot.ports.map { port, addresses in
                let container = snapshot.command.lowercased() == "com.docker.backend"
                    ? dockerContainersByHostPort[port]
                    : nil

                return ListeningProcess(
                    pids: [snapshot.pid],
                    command: snapshot.command,
                    user: snapshot.user,
                    port: port,
                    addresses: Array(addresses).sorted(),
                    project: metadataByPID[snapshot.pid],
                    container: container
                )
            }
        }

        return Self.coalesced(rawProcesses).sorted {
            if $0.port == $1.port {
                return ($0.primaryPID ?? 0) < ($1.primaryPID ?? 0)
            }

            return $0.port < $1.port
        }
    }

    private static func port(from endpoint: String) -> Int? {
        if endpoint.hasPrefix("[") {
            guard let bracket = endpoint.lastIndex(of: "]") else { return nil }
            let remainder = endpoint[endpoint.index(after: bracket)...]
            guard remainder.first == ":" else { return nil }
            return Int(remainder.dropFirst())
        }

        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return Int(endpoint[endpoint.index(after: colon)...])
    }

    private static func address(from endpoint: String) -> String {
        if endpoint.hasPrefix("["), let bracket = endpoint.lastIndex(of: "]") {
            return String(endpoint[endpoint.startIndex...bracket])
        }

        guard let colon = endpoint.lastIndex(of: ":") else {
            return endpoint
        }

        return String(endpoint[..<colon])
    }

    private static func coalesced(_ processes: [ListeningProcess]) -> [ListeningProcess] {
        struct Key: Hashable {
            let command: String
            let user: String
            let port: Int
            let project: ProjectMetadata?
            let container: DockerContainer?
        }

        var pidsByKey: [Key: Set<Int32>] = [:]
        var addressesByKey: [Key: Set<String>] = [:]

        for process in processes {
            let key = Key(
                command: process.command,
                user: process.user,
                port: process.port,
                project: process.project,
                container: process.container
            )
            pidsByKey[key, default: []].formUnion(process.pids)
            addressesByKey[key, default: []].formUnion(process.addresses)
        }

        return pidsByKey.map { key, pids in
            ListeningProcess(
                pids: Array(pids).sorted(),
                command: key.command,
                user: key.user,
                port: key.port,
                addresses: Array(addressesByKey[key] ?? []).sorted(),
                project: key.project,
                container: key.container
            )
        }
    }

    private static func dockerContainersByHostPort() -> [Int: DockerContainer] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/docker") else {
            return [:]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = [
            "ps",
            "--format",
            "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var result: [Int: DockerContainer] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }

            let id = fields[0]
            let name = fields[1]
            let image = fields[2]
            let ports = fields[3]
            let composeProject = fields[4].isEmpty ? nil : fields[4]
            let composeService = fields[5].isEmpty ? nil : fields[5]
            let workingDirectory = fields[6].isEmpty ? nil : fields[6]

            for mapping in dockerPortMappings(from: ports) {
                result[mapping.hostPort] = DockerContainer(
                    id: id,
                    name: name,
                    image: image,
                    composeProject: composeProject,
                    composeService: composeService,
                    workingDirectory: workingDirectory,
                    hostPort: mapping.hostPort,
                    containerPort: mapping.containerPort
                )
            }
        }

        return result
    }

    private static func dockerPortMappings(from ports: String) -> [(hostPort: Int, containerPort: Int?)] {
        let pattern = #"(?:(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]|\*)\:)?(\d+)->(\d+)\/tcp"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(ports.startIndex..<ports.endIndex, in: ports)
        let matches = regex.matches(in: ports, range: range)
        var seen = Set<Int>()
        var mappings: [(hostPort: Int, containerPort: Int?)] = []

        for match in matches {
            guard
                let hostRange = Range(match.range(at: 1), in: ports),
                let hostPort = Int(ports[hostRange])
            else {
                continue
            }

            if seen.contains(hostPort) {
                continue
            }

            let containerPort: Int?
            if let containerRange = Range(match.range(at: 2), in: ports) {
                containerPort = Int(ports[containerRange])
            } else {
                containerPort = nil
            }

            seen.insert(hostPort)
            mappings.append((hostPort, containerPort))
        }

        return mappings
    }

    private static func metadataByPID(for snapshots: [ProcessSnapshot]) -> [Int32: ProjectMetadata] {
        let commandNameByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0.command) })
        let pids = snapshots.map(\.pid)
        let uniquePIDs = Array(Set(pids)).sorted()
        if uniquePIDs.isEmpty {
            return [:]
        }

        let cwdByPID = cwdByPID(for: uniquePIDs)
        let commandByPID = commandByPID(for: uniquePIDs)
        var metadata: [Int32: ProjectMetadata] = [:]
        var metadataByCWD: [String: ProjectMetadata] = [:]

        for pid in uniquePIDs {
            let cwd = cwdByPID[pid]
            let command = commandByPID[pid]
            let commandName = commandNameByPID[pid]

            if !isLikelyProjectProcess(commandName: commandName, commandLine: command) {
                continue
            }

            let inferred: ProjectMetadata

            if let cwd, let cached = metadataByCWD[cwd] {
                inferred = cached
            } else {
                inferred = inferProject(cwd: cwd, command: command)

                if let cwd {
                    metadataByCWD[cwd] = inferred
                }
            }

            if inferred.cwd != nil || inferred.root != nil || inferred.framework != nil {
                metadata[pid] = inferred
            }
        }

        return metadata
    }

    private static func isLikelyProjectProcess(commandName: String?, commandLine: String?) -> Bool {
        let text = [commandName, commandLine]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return [
            "node",
            "bun",
            "deno",
            "npm",
            "pnpm",
            "yarn",
            "vite",
            "next",
            "astro",
            "python",
            "ruby",
            "rails",
            "go ",
            "air",
            "cargo"
        ].contains { text.contains($0) }
    }

    private static func cwdByPID(for pids: [Int32]) -> [Int32: String] {
        var result: [Int32: String] = [:]

        for pid in pids {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let count = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)

            guard count == size else {
                continue
            }

            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }

            if !path.isEmpty {
                result[pid] = path
            }
        }

        return result
    }

    private static func commandByPID(for pids: [Int32]) -> [Int32: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-p",
            pids.map(String.init).joined(separator: ","),
            "-o",
            "pid=",
            "-o",
            "command="
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var result: [Int32: String] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }

            let pidText = String(line[..<firstSpace])
            let command = String(line[firstSpace...]).trimmingCharacters(in: .whitespaces)

            if let pid = Int32(pidText) {
                result[pid] = command
            }
        }

        return result
    }

    private static func inferProject(cwd: String?, command: String?) -> ProjectMetadata {
        let projectRoot = cwd.flatMap(packageRoot(from:)) ?? cwd.flatMap(otherProjectRoot(from:))
        let name = projectName(root: projectRoot, cwd: cwd)
        let framework = frameworkName(root: projectRoot, cwd: cwd, command: command)
        let isOrphan = isOrphanProject(cwd: cwd, root: projectRoot, command: command)
        let isStaleWorktree = isOrphan && isAgentWorktreePath(cwd)

        return ProjectMetadata(
            cwd: cwd,
            root: projectRoot,
            name: name,
            framework: framework,
            isOrphan: isOrphan,
            isStaleWorktree: isStaleWorktree
        )
    }

    private static func packageRoot(from cwd: String) -> String? {
        firstAncestor(from: cwd, containing: "package.json")
    }

    private static func otherProjectRoot(from cwd: String) -> String? {
        for marker in ["pyproject.toml", "requirements.txt", "Gemfile", "go.mod", "Cargo.toml"] {
            if let root = firstAncestor(from: cwd, containing: marker) {
                return root
            }
        }

        return nil
    }

    private static func firstAncestor(from cwd: String, containing filename: String) -> String? {
        if cwd.hasPrefix("/System/") || cwd.hasPrefix("/Library/") || cwd.hasPrefix("/Applications/") {
            return nil
        }

        var path = cwd
        var depth = 0

        while true {
            let candidate = "\(path)/\(filename)"
            if access(candidate, F_OK) == 0 {
                return path
            }

            let next = URL(fileURLWithPath: path).deletingLastPathComponent().path
            depth += 1

            if next == path || next == "/" || depth >= 8 {
                return nil
            }

            path = next
        }
    }

    private static func projectName(root: String?, cwd: String?) -> String {
        if let root, let package = packageJSON(at: root), let packageName = package["name"] as? String {
            return packageName.split(separator: "/").last.map(String.init) ?? packageName
        }

        let path = root ?? cwd
        return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
    }

    private static func frameworkName(root: String?, cwd: String?, command: String?) -> String? {
        if let root, let package = packageJSON(at: root) {
            let dependencies = packageDependencies(package)

            if hasTanStackStartSignal(root: root, dependencies: dependencies, package: package) {
                return "TanStack Start"
            }

            if hasTanStackSignal(root: root, dependencies: dependencies, package: package) {
                return "TanStack"
            }

            let checks: [(String, String)] = [
                ("next", "Next.js"),
                ("astro", "Astro"),
                ("@remix-run/dev", "Remix"),
                ("@sveltejs/kit", "SvelteKit"),
                ("nuxt", "Nuxt"),
                ("vite", "Vite"),
                ("@angular/core", "Angular"),
                ("react-scripts", "Create React App"),
                ("expo", "Expo"),
                ("electron", "Electron")
            ]

            for (dependency, name) in checks where dependencies.contains(dependency) {
                return name
            }

            if dependencies.contains("react") {
                return "React"
            }

            if dependencies.contains("vue") {
                return "Vue"
            }
        }

        if let cwd, let cachedFramework = viteCacheFramework(cwd: cwd) {
            return cachedFramework
        }

        if let root, fileContains(root: root, filename: "Gemfile", needles: ["rails"]) {
            return "Rails"
        }

        if let root, fileContains(root: root, filename: "requirements.txt", needles: ["django"]) {
            return "Django"
        }

        if let root, fileContains(root: root, filename: "requirements.txt", needles: ["fastapi"]) {
            return "FastAPI"
        }

        if let command = command?.lowercased() {
            if command.contains("tanstack") {
                return "TanStack"
            }

            if command.contains("next") {
                return "Next.js"
            }

            if command.contains("astro") {
                return "Astro"
            }

            if command.contains("vite") {
                return "Vite"
            }
        }

        return nil
    }

    private static func viteCacheFramework(cwd: String) -> String? {
        let metadataPath = "\(cwd)/.vite/deps/_metadata.json"
        guard let contents = try? String(contentsOfFile: metadataPath, encoding: .utf8).lowercased() else {
            return nil
        }

        if contents.contains("@tanstack/react-start") || contents.contains("@tanstack/start") {
            return "TanStack Start"
        }

        if contents.contains("@tanstack/") {
            return "TanStack"
        }

        if contents.contains("astro") {
            return "Astro"
        }

        if contents.contains("next") {
            return "Next.js"
        }

        return nil
    }

    private static func isOrphanProject(cwd: String?, root: String?, command: String?) -> Bool {
        guard let cwd else {
            return false
        }

        if access(cwd, F_OK) != 0 {
            return true
        }

        guard root == nil else {
            return false
        }

        let lowerCommand = command?.lowercased() ?? ""

        return [
            "/node_modules/",
            "node_modules/.bin",
            "vite",
            "next",
            "astro",
            "tanstack",
            "npm ",
            "pnpm ",
            "yarn ",
            "bun ",
            "deno "
        ].contains { lowerCommand.contains($0) }
    }

    private static func isAgentWorktreePath(_ cwd: String?) -> Bool {
        guard let cwd else {
            return false
        }

        let lower = cwd.lowercased()
        return [
            "/conductor/workspaces/",
            "/claude/workspaces/",
            "/codex/workspaces/",
            "/.codex/workspaces/",
            "/.claude/workspaces/"
        ].contains { lower.contains($0) }
    }

    private static func hasTanStackStartSignal(
        root: String,
        dependencies: Set<String>,
        package: [String: Any]
    ) -> Bool {
        if dependencies.contains("@tanstack/start") || dependencies.contains("@tanstack/react-start") {
            return true
        }

        if packageScripts(package).contains(where: { $0.contains("tanstack") && $0.contains("start") }) {
            return true
        }

        return projectFilesContain(
            root: root,
            filenames: [
                "app.config.ts",
                "app.config.js",
                "app.config.mjs",
                "vite.config.ts",
                "vite.config.js",
                "vite.config.mjs",
                "src/router.tsx",
                "src/router.ts",
                "app/router.tsx",
                "app/router.ts"
            ],
            needles: [
                "@tanstack/react-start",
                "@tanstack/start",
                "tanstackStart",
                "createStart"
            ]
        )
    }

    private static func hasTanStackSignal(
        root: String,
        dependencies: Set<String>,
        package: [String: Any]
    ) -> Bool {
        if dependencies.contains(where: { $0.hasPrefix("@tanstack/") }) {
            return true
        }

        if packageScripts(package).contains(where: { $0.contains("tanstack") }) {
            return true
        }

        return projectFilesContain(
            root: root,
            filenames: [
                "vite.config.ts",
                "vite.config.js",
                "vite.config.mjs",
                "tsr.config.json",
                "src/router.tsx",
                "src/router.ts",
                "app/router.tsx",
                "app/router.ts",
                "src/routeTree.gen.ts",
                "app/routeTree.gen.ts"
            ],
            needles: [
                "@tanstack/",
                "createRouter",
                "createFileRoute",
                "TanStackRouter"
            ]
        )
    }

    private static func packageJSON(at root: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: root).appendingPathComponent("package.json")

        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return json
    }

    private static func packageDependencies(_ package: [String: Any]) -> Set<String> {
        var dependencies = Set<String>()

        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            guard let values = package[key] as? [String: Any] else { continue }
            dependencies.formUnion(values.keys)
        }

        return dependencies
    }

    private static func packageScripts(_ package: [String: Any]) -> [String] {
        guard let scripts = package["scripts"] as? [String: Any] else {
            return []
        }

        return scripts.values.compactMap { ($0 as? String)?.lowercased() }
    }

    private static func projectFilesContain(root: String, filenames: [String], needles: [String]) -> Bool {
        for filename in filenames {
            if fileContains(root: root, filename: filename, needles: needles) {
                return true
            }
        }

        return false
    }

    private static func fileContains(root: String, filename: String, needles: [String]) -> Bool {
        let url = URL(fileURLWithPath: root).appendingPathComponent(filename)
        guard let contents = try? String(contentsOf: url, encoding: .utf8).lowercased() else {
            return false
        }

        return needles.contains { contents.contains($0) }
    }
}

@MainActor
final class PortManagerApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var currentProcesses: [ListeningProcess] = []
    private var isRefreshing = false
    private var lastRefresh: Date?
    private var networkAddress: String?
    private var settingsWindow: NSWindow?
    private var ignoredPortsTextView: NSTextView?
    private var ignoredCommandsTextView: NSTextView?
    private var ignoredTargetsTextView: NSTextView?

    private var showAllProcesses: Bool {
        get {
            UserDefaults.standard.bool(forKey: "showAllProcesses")
        }

        set {
            UserDefaults.standard.set(newValue, forKey: "showAllProcesses")
        }
    }

    private var pinnedKeys: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "pinnedKeys") ?? [])
        }

        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "pinnedKeys")
        }
    }

    private var ignoredPorts: Set<Int> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "ignoredPorts")?.compactMap(Int.init) ?? [])
        }

        set {
            UserDefaults.standard.set(newValue.map(String.init).sorted(), forKey: "ignoredPorts")
        }
    }

    private var ignoredCommands: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "ignoredCommands") ?? [])
        }

        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "ignoredCommands")
        }
    }

    private var ignoredTargets: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "ignoredTargets") ?? [])
        }

        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "ignoredTargets")
        }
    }

    private var visibleProcesses: [ListeningProcess] {
        let processes = currentProcesses.filter { !isIgnored($0) }

        if showAllProcesses {
            return processes
        }

        return processes.filter { !$0.hiddenByDefault }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        rebuildMenu()
        requestRefresh(force: true)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Port Manager")
        button.imagePosition = .imageRight
        button.title = "0"
        button.toolTip = "Port Manager"
    }

    private func configureMenu() {
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        requestRefresh()
    }

    private func requestRefresh(force: Bool = false) {
        if isRefreshing {
            return
        }

        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 5 {
            return
        }

        isRefreshing = true

        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                (
                    processes: PortScanner().listeningProcesses(),
                    networkAddress: PortManagerApp.localIPAddressValue()
                )
            }.value

            guard let self else { return }

            currentProcesses = snapshot.processes
            networkAddress = snapshot.networkAddress
            lastRefresh = Date()
            isRefreshing = false
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let processes = visibleProcesses

        let heading = NSMenuItem(title: "Listening Processes", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if processes.isEmpty {
            let title = isRefreshing ? "Scanning..." : "No listening ports found"
            let empty = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            addConflictItems(for: processes, to: menu)
            addProcessItems(processes, to: menu)
        }

        menu.addItem(.separator())

        let preferences = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferences.isEnabled = false
        menu.addItem(preferences)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let loginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleOpenAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = openAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        let showAllItem = NSMenuItem(
            title: "Show System Ports",
            action: #selector(toggleShowAllProcesses(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = self
        showAllItem.state = showAllProcesses ? .on : .off
        menu.addItem(showAllItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let aboutItem = NSMenuItem(title: "About Port Manager", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem.button {
            button.title = "\(processes.count)"
        }
    }

    private func addConflictItems(for processes: [ListeningProcess], to menu: NSMenu) {
        let conflicts = Dictionary(grouping: processes) { $0.port }
            .filter { _, processes in processes.count > 1 }
            .map { port, processes in ProcessGroup(name: "\(port)", processes: processes) }
            .sorted { Int($0.name) ?? 0 < Int($1.name) ?? 0 }

        guard !conflicts.isEmpty else { return }

        let item = NSMenuItem(
            title: "Port Conflicts · \(conflicts.count)",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        for conflict in conflicts {
            submenu.addItem(conflictMenuItem(for: conflict))
        }

        item.submenu = submenu
        menu.addItem(item)
        menu.addItem(.separator())
    }

    private func conflictMenuItem(for group: ProcessGroup) -> NSMenuItem {
        let port = group.name
        let item = NSMenuItem(
            title: "\(port) · \(group.processes.count) listeners",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let heading = NSMenuItem(title: "Conflicting Listeners", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        submenu.addItem(heading)

        for process in group.sortedProcesses {
            submenu.addItem(menuItem(for: process))
        }

        item.submenu = submenu
        return item
    }

    private func isIgnored(_ process: ListeningProcess) -> Bool {
        if ignoredPorts.contains(process.port) {
            return true
        }

        let command = process.command.lowercased()
        let prettyCommand = process.prettyCommand.lowercased()
        if ignoredCommands.contains(where: { command.contains($0) || prettyCommand.contains($0) }) {
            return true
        }

        guard let target = process.ignoreTargetKey else {
            return false
        }

        return ignoredTargets.contains { target.contains($0) }
    }

    private func addProcessItems(_ processes: [ListeningProcess], to menu: NSMenu) {
        let pinned = pinnedKeys
        let pinnedProcesses = processes.filter { pinned.contains($0.pinKey) }
        let unpinnedProcesses = processes.filter { !pinned.contains($0.pinKey) }
        var addedPinnedSection = false

        if !pinnedProcesses.isEmpty {
            let pinnedHeading = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            pinnedHeading.isEnabled = false
            menu.addItem(pinnedHeading)
            addPinnedItems(pinnedProcesses, to: menu)
            addedPinnedSection = true
        }

        let dockerProcesses = unpinnedProcesses.filter { $0.container != nil }
        let nonDockerProcesses = unpinnedProcesses.filter { $0.container == nil }
        let staleWorktreeProcesses = nonDockerProcesses.filter { $0.project?.isStaleWorktree == true }
        let orphanProcesses = nonDockerProcesses.filter {
            $0.project?.isOrphan == true && $0.project?.isStaleWorktree != true
        }
        let regularProcesses = nonDockerProcesses.filter { $0.project?.isOrphan != true }
        var addedSpecialGroup = false

        if !dockerProcesses.isEmpty {
            if addedPinnedSection {
                menu.addItem(.separator())
                addedPinnedSection = false
            }

            let group = ProcessGroup(name: "Docker Containers", processes: dockerProcesses)
            menu.addItem(dockerRootMenuItem(for: group))
            addedSpecialGroup = true
        }

        if !staleWorktreeProcesses.isEmpty {
            if addedPinnedSection || addedSpecialGroup {
                menu.addItem(.separator())
                addedPinnedSection = false
            }

            let group = ProcessGroup(name: "Stale Worktrees", processes: staleWorktreeProcesses)
            menu.addItem(groupMenuItem(for: group))
            addedSpecialGroup = true
        }

        if !orphanProcesses.isEmpty {
            if addedPinnedSection || addedSpecialGroup {
                menu.addItem(.separator())
                addedPinnedSection = false
            }

            let group = ProcessGroup(name: "Orphan Processes", processes: orphanProcesses)
            menu.addItem(groupMenuItem(for: group))
            addedSpecialGroup = true
        }

        if addedSpecialGroup && !regularProcesses.isEmpty {
            menu.addItem(.separator())
        }

        if addedPinnedSection && !regularProcesses.isEmpty {
            menu.addItem(.separator())
        }

        let grouped = Dictionary(grouping: regularProcesses) { $0.groupName }
        let projectGroupNames = Set(grouped.compactMap { name, processes in
            processes.count > 1 && processes.contains { $0.project != nil } ? name : nil
        })

        guard regularProcesses.count > 24 else {
            addRegularProcessItems(
                regularProcesses,
                grouped: grouped,
                groupNames: projectGroupNames,
                to: menu
            )

            return
        }

        let groupNames = Set(grouped.compactMap { name, processes in
            processes.count >= 4 ? name : nil
        }).union(projectGroupNames)

        addRegularProcessItems(
            regularProcesses,
            grouped: grouped,
            groupNames: groupNames,
            to: menu
        )
    }

    private func addPinnedItems(_ processes: [ListeningProcess], to menu: NSMenu) {
        let grouped = Dictionary(grouping: processes) { $0.pinKey }
        let groups = grouped.values
            .map { ProcessGroup(name: $0.first?.groupName ?? "Pinned", processes: $0) }
            .sorted {
                let left = $0.primaryProcess?.displayName ?? $0.name
                let right = $1.primaryProcess?.displayName ?? $1.name
                return left < right
            }

        for group in groups {
            if group.allDocker, let container = group.dockerContainers.first {
                if group.processes.count == 1, let process = group.processes.first {
                    menu.addItem(menuItem(for: process))
                } else {
                    menu.addItem(dockerContainerMenuItem(for: group, container: container))
                }

                continue
            }

            if group.processes.count > 1 || group.project != nil {
                menu.addItem(projectGroupMenuItem(for: group))
            } else if let process = group.processes.first {
                menu.addItem(menuItem(for: process))
            }
        }
    }

    private func addRegularProcessItems(
        _ processes: [ListeningProcess],
        grouped: [String: [ListeningProcess]],
        groupNames: Set<String>,
        to menu: NSMenu
    ) {
        var addedGroups = Set<String>()

        for process in processes {
            let name = process.groupName

            guard groupNames.contains(name) else {
                menu.addItem(menuItem(for: process))
                continue
            }

            if addedGroups.contains(name) {
                continue
            }

            let groupProcesses = (grouped[name] ?? []).sorted {
                if $0.port == $1.port {
                    return ($0.primaryPID ?? 0) < ($1.primaryPID ?? 0)
                }

                return $0.port < $1.port
            }

            let group = ProcessGroup(name: name, processes: groupProcesses)
            menu.addItem(projectGroupMenuItem(for: group))
            addedGroups.insert(name)
        }
    }

    private func projectGroupMenuItem(for group: ProcessGroup) -> NSMenuItem {
        guard let primaryProcess = group.primaryProcess else {
            return groupMenuItem(for: group)
        }

        let title = group.processes.count > 1
            ? "\(primaryProcess.displayName) · \(group.processes.count) ports"
            : primaryProcess.displayName

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let openItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        openItem.representedObject = primaryProcess
        openItem.target = self
        submenu.addItem(openItem)

        let copyLocalItem = NSMenuItem(title: "Copy Local URL", action: #selector(copyLocalURL(_:)), keyEquivalent: "")
        copyLocalItem.representedObject = primaryProcess
        copyLocalItem.target = self
        submenu.addItem(copyLocalItem)

        let copyNetworkItem = NSMenuItem(title: "Copy Network URL", action: #selector(copyNetworkURL(_:)), keyEquivalent: "")
        copyNetworkItem.representedObject = primaryProcess
        copyNetworkItem.target = self
        copyNetworkItem.isEnabled = networkAddress != nil
        submenu.addItem(copyNetworkItem)

        if let pinKey = group.pinKey {
            addPinItem(to: submenu, key: pinKey, pinTitle: group.pinTitle, unpinTitle: group.unpinTitle)
        }

        if let target = group.project.map({ ($0.root ?? $0.cwd ?? $0.name).lowercased() }) {
            addIgnoreItem(to: submenu, title: "Ignore Project", kind: "target", value: target)
        }

        submenu.addItem(.separator())

        let killAllItem = NSMenuItem(title: group.killTitle, action: #selector(killProcessGroup(_:)), keyEquivalent: "")
        killAllItem.representedObject = group
        killAllItem.target = self
        submenu.addItem(killAllItem)

        if let project = group.project, let displayPath = project.displayPath {
            submenu.addItem(.separator())

            let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            submenu.addItem(projectItem)

            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            let copyProjectItem = NSMenuItem(title: "Copy Project Path", action: #selector(copyGroupProjectPath(_:)), keyEquivalent: "")
            copyProjectItem.representedObject = group
            copyProjectItem.target = self
            submenu.addItem(copyProjectItem)

            let revealProjectItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealGroupProject(_:)), keyEquivalent: "")
            revealProjectItem.representedObject = group
            revealProjectItem.target = self
            submenu.addItem(revealProjectItem)

            addProjectLaunchItems(
                to: submenu,
                path: project.root ?? project.cwd ?? displayPath,
                restartTarget: RestartTarget(path: project.root ?? project.cwd ?? displayPath, pids: group.pids)
            )
        }

        let helperProcesses = group.sortedProcesses.filter { $0 != primaryProcess }
        if !helperProcesses.isEmpty {
            submenu.addItem(.separator())

            let portsItem = NSMenuItem(title: "Other Listening Ports", action: nil, keyEquivalent: "")
            portsItem.isEnabled = false
            submenu.addItem(portsItem)

            for process in helperProcesses {
                submenu.addItem(menuItem(for: process))
            }
        }

        item.toolTip = group.project?.displayPath
        item.submenu = submenu
        return item
    }

    private func dockerRootMenuItem(for group: ProcessGroup) -> NSMenuItem {
        let containers = group.dockerContainers
        let item = NSMenuItem(
            title: "Docker Containers · \(containers.count) containers · \(group.processes.count) ports",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let stopAllItem = NSMenuItem(title: "Stop All Containers (\(containers.count))", action: #selector(stopContainerGroup(_:)), keyEquivalent: "")
        stopAllItem.representedObject = group
        stopAllItem.target = self
        submenu.addItem(stopAllItem)

        submenu.addItem(.separator())

        let processesByContainer = Dictionary(grouping: group.sortedProcesses) { process in
            process.container?.id ?? ""
        }

        for container in containers {
            let processes = processesByContainer[container.id] ?? []
            if processes.count == 1, let process = processes.first {
                submenu.addItem(menuItem(for: process))
                continue
            }

            let containerGroup = ProcessGroup(name: container.displayName, processes: processes)
            submenu.addItem(dockerContainerMenuItem(for: containerGroup, container: container))
        }

        item.submenu = submenu
        return item
    }

    private func dockerContainerMenuItem(for group: ProcessGroup, container: DockerContainer) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(container.displayName) · \(group.processes.count) ports",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let stopItem = NSMenuItem(title: "Stop Container (\(container.name))", action: #selector(stopContainerGroup(_:)), keyEquivalent: "")
        stopItem.representedObject = group
        stopItem.target = self
        submenu.addItem(stopItem)

        if let pinKey = group.pinKey {
            addPinItem(to: submenu, key: pinKey, pinTitle: group.pinTitle, unpinTitle: group.unpinTitle)
        }

        addIgnoreItem(
            to: submenu,
            title: "Ignore Container",
            kind: "target",
            value: container.displayName.lowercased()
        )

        submenu.addItem(.separator())

        let dockerItem = NSMenuItem(title: "Docker", action: nil, keyEquivalent: "")
        dockerItem.isEnabled = false
        submenu.addItem(dockerItem)

        let nameItem = NSMenuItem(title: container.name, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        submenu.addItem(nameItem)

        let imageItem = NSMenuItem(title: container.image, action: nil, keyEquivalent: "")
        imageItem.isEnabled = false
        submenu.addItem(imageItem)

        if let displayPath = container.displayPath {
            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            if let path = container.workingDirectory {
                addProjectLaunchItems(to: submenu, path: path, restartTarget: nil)
            }
        }

        submenu.addItem(.separator())

        for process in group.sortedProcesses {
            submenu.addItem(menuItem(for: process))
        }

        item.toolTip = container.displayPath
        item.submenu = submenu
        return item
    }

    private func groupMenuItem(for group: ProcessGroup) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(group.name) · \(group.processes.count) ports",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let killTitle: String
        let killAction: Selector

        if group.allDocker {
            killTitle = "Stop All Containers (\(group.dockerContainers.count))"
            killAction = #selector(stopContainerGroup(_:))
        } else if group.allStaleWorktrees {
            killTitle = "Kill All Stale Worktree Processes (\(group.pids.count) ids)"
            killAction = #selector(killProcessGroup(_:))
        } else if group.allOrphans {
            killTitle = "Kill All Orphan Processes (\(group.pids.count) ids)"
            killAction = #selector(killProcessGroup(_:))
        } else {
            killTitle = group.killTitle
            killAction = #selector(killProcessGroup(_:))
        }

        let killAllItem = NSMenuItem(title: killTitle, action: killAction, keyEquivalent: "")
        killAllItem.representedObject = group
        killAllItem.target = self
        submenu.addItem(killAllItem)

        if group.allStaleWorktrees {
            submenu.addItem(.separator())

            let staleItem = NSMenuItem(title: "Agent worktree project files are missing", action: nil, keyEquivalent: "")
            staleItem.isEnabled = false
            submenu.addItem(staleItem)
        }

        if let pinKey = group.pinKey {
            addPinItem(to: submenu, key: pinKey, pinTitle: group.pinTitle, unpinTitle: group.unpinTitle)
        }

        if group.allOrphans {
            submenu.addItem(.separator())

            let orphanItem = NSMenuItem(title: "Project folders or files are missing", action: nil, keyEquivalent: "")
            orphanItem.isEnabled = false
            submenu.addItem(orphanItem)
        }

        if group.allDocker {
            submenu.addItem(.separator())

            let dockerItem = NSMenuItem(title: "Docker Containers", action: nil, keyEquivalent: "")
            dockerItem.isEnabled = false
            submenu.addItem(dockerItem)

            for container in group.dockerContainers {
                let portText = container.containerPort.map { "\(container.hostPort) -> \($0)" } ?? "\(container.hostPort)"
                let containerItem = NSMenuItem(title: "\(container.name) · \(portText)", action: nil, keyEquivalent: "")
                containerItem.isEnabled = false
                submenu.addItem(containerItem)
            }
        }

        if let project = group.project, let displayPath = project.displayPath {
            submenu.addItem(.separator())

            let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            submenu.addItem(projectItem)

            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            let copyProjectItem = NSMenuItem(
                title: "Copy Project Path",
                action: #selector(copyGroupProjectPath(_:)),
                keyEquivalent: ""
            )
            copyProjectItem.representedObject = group
            copyProjectItem.target = self
            submenu.addItem(copyProjectItem)

            let revealProjectItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealGroupProject(_:)),
                keyEquivalent: ""
            )
            revealProjectItem.representedObject = group
            revealProjectItem.target = self
            submenu.addItem(revealProjectItem)

            addProjectLaunchItems(
                to: submenu,
                path: project.root ?? project.cwd ?? displayPath,
                restartTarget: RestartTarget(path: project.root ?? project.cwd ?? displayPath, pids: group.pids)
            )
        }

        submenu.addItem(.separator())

        for process in group.sortedProcesses {
            submenu.addItem(menuItem(for: process))
        }

        item.toolTip = group.project?.displayPath
        item.submenu = submenu
        return item
    }

    private func menuItem(for process: ListeningProcess) -> NSMenuItem {
        let item = NSMenuItem(title: process.displayName, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let openItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        openItem.representedObject = process
        openItem.target = self
        submenu.addItem(openItem)

        let copyLocalItem = NSMenuItem(title: "Copy Local URL", action: #selector(copyLocalURL(_:)), keyEquivalent: "")
        copyLocalItem.representedObject = process
        copyLocalItem.target = self
        submenu.addItem(copyLocalItem)

        let copyNetworkItem = NSMenuItem(title: "Copy Network URL", action: #selector(copyNetworkURL(_:)), keyEquivalent: "")
        copyNetworkItem.representedObject = process
        copyNetworkItem.target = self
        copyNetworkItem.isEnabled = networkAddress != nil
        submenu.addItem(copyNetworkItem)

        addPinItem(
            to: submenu,
            key: process.pinKey,
            pinTitle: process.pinTitle,
            unpinTitle: process.unpinTitle
        )
        addIgnoreItem(to: submenu, title: "Ignore Port", kind: "port", value: "\(process.port)")

        if let target = process.ignoreTargetKey {
            addIgnoreItem(
                to: submenu,
                title: process.container == nil ? "Ignore Project" : "Ignore Container",
                kind: "target",
                value: target
            )
        } else {
            addIgnoreItem(
                to: submenu,
                title: "Ignore App",
                kind: "command",
                value: process.command.lowercased()
            )
        }

        if let container = process.container {
            submenu.addItem(.separator())

            let dockerItem = NSMenuItem(title: "Docker", action: nil, keyEquivalent: "")
            dockerItem.isEnabled = false
            submenu.addItem(dockerItem)

            let nameItem = NSMenuItem(title: container.name, action: nil, keyEquivalent: "")
            nameItem.isEnabled = false
            submenu.addItem(nameItem)

            let imageItem = NSMenuItem(title: container.image, action: nil, keyEquivalent: "")
            imageItem.isEnabled = false
            submenu.addItem(imageItem)

            if let composeProject = container.composeProject, let composeService = container.composeService {
                let composeItem = NSMenuItem(title: "\(composeProject) / \(composeService)", action: nil, keyEquivalent: "")
                composeItem.isEnabled = false
                submenu.addItem(composeItem)
            }

            if let displayPath = container.displayPath {
                let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
                pathItem.isEnabled = false
                submenu.addItem(pathItem)

                let copyPathItem = NSMenuItem(title: "Copy Project Path", action: #selector(copyContainerProjectPath(_:)), keyEquivalent: "")
                copyPathItem.representedObject = process
                copyPathItem.target = self
                submenu.addItem(copyPathItem)

                let revealPathItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealContainerProject(_:)), keyEquivalent: "")
                revealPathItem.representedObject = process
                revealPathItem.target = self
                submenu.addItem(revealPathItem)

                addProjectLaunchItems(to: submenu, path: container.workingDirectory, restartTarget: nil)
            }

            let copyNameItem = NSMenuItem(title: "Copy Container Name", action: #selector(copyContainerName(_:)), keyEquivalent: "")
            copyNameItem.representedObject = process
            copyNameItem.target = self
            submenu.addItem(copyNameItem)
        }

        if let project = process.project, let displayPath = project.displayPath {
            submenu.addItem(.separator())

            let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            submenu.addItem(projectItem)

            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            let copyProjectItem = NSMenuItem(
                title: "Copy Project Path",
                action: #selector(copyProjectPath(_:)),
                keyEquivalent: ""
            )
            copyProjectItem.representedObject = process
            copyProjectItem.target = self
            submenu.addItem(copyProjectItem)

            let revealProjectItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealProject(_:)),
                keyEquivalent: ""
            )
            revealProjectItem.representedObject = process
            revealProjectItem.target = self
            submenu.addItem(revealProjectItem)

            addProjectLaunchItems(
                to: submenu,
                path: project.root ?? project.cwd ?? displayPath,
                restartTarget: RestartTarget(path: project.root ?? project.cwd ?? displayPath, pids: process.pids)
            )
        }

        submenu.addItem(.separator())

        let killAction: Selector = process.container == nil ? #selector(killProcess(_:)) : #selector(stopContainer(_:))
        let killItem = NSMenuItem(title: process.killTitle, action: killAction, keyEquivalent: "")
        killItem.representedObject = process
        killItem.target = self
        submenu.addItem(killItem)

        item.toolTip = process.project?.displayPath
        item.submenu = submenu
        return item
    }

    private func addProjectLaunchItems(to menu: NSMenu, path: String?, restartTarget: RestartTarget?) {
        guard let path, !path.isEmpty else { return }

        let ghosttyItem = NSMenuItem(title: "Open in Ghostty", action: #selector(openInGhostty(_:)), keyEquivalent: "")
        ghosttyItem.representedObject = path
        ghosttyItem.target = self
        menu.addItem(ghosttyItem)

        let codeItem = NSMenuItem(title: "Open in VS Code", action: #selector(openInVSCode(_:)), keyEquivalent: "")
        codeItem.representedObject = path
        codeItem.target = self
        menu.addItem(codeItem)

        if let restartTarget, devCommand(for: path) != nil {
            let restartItem = NSMenuItem(title: "Restart Dev Server", action: #selector(restartDevServer(_:)), keyEquivalent: "")
            restartItem.representedObject = restartTarget
            restartItem.target = self
            menu.addItem(restartItem)
        }
    }

    private func addPinItem(to menu: NSMenu, key: String, pinTitle: String, unpinTitle: String) {
        let isPinned = pinnedKeys.contains(key)
        let item = NSMenuItem(
            title: isPinned ? unpinTitle : pinTitle,
            action: isPinned ? #selector(unpinItem(_:)) : #selector(pinItem(_:)),
            keyEquivalent: ""
        )
        item.representedObject = key
        item.target = self
        menu.addItem(item)
    }

    private func addIgnoreItem(to menu: NSMenu, title: String, kind: String, value: String) {
        let item = NSMenuItem(title: title, action: #selector(ignoreItem(_:)), keyEquivalent: "")
        item.representedObject = "\(kind):\(value)"
        item.target = self
        menu.addItem(item)
    }

    @objc private func pinItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var keys = pinnedKeys
        keys.insert(key)
        pinnedKeys = keys
        rebuildMenu()
    }

    @objc private func openInGhostty(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        launchProcess(
            executable: "/usr/bin/open",
            arguments: ["-na", "Ghostty", "--args", "--working-directory=\(path)"]
        )
    }

    @objc private func openInVSCode(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }

        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/code") {
            launchProcess(executable: "/usr/local/bin/code", arguments: [path])
        } else {
            launchProcess(executable: "/usr/bin/open", arguments: ["-a", "Visual Studio Code", path])
        }
    }

    @objc private func restartDevServer(_ sender: NSMenuItem) {
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

    @objc private func unpinItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var keys = pinnedKeys
        keys.remove(key)
        pinnedKeys = keys
        rebuildMenu()
    }

    @objc private func ignoreItem(_ sender: NSMenuItem) {
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

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ListeningProcess else { return }
        NSWorkspace.shared.open(localURL(for: process))
    }

    @objc private func copyLocalURL(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ListeningProcess else { return }
        copyToPasteboard(localURL(for: process).absoluteString)
    }

    @objc private func copyNetworkURL(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let address = networkAddress
        else {
            return
        }

        copyToPasteboard("http://\(address):\(process.port)")
    }

    @objc private func copyProjectPath(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.project?.root ?? process.project?.cwd
        else {
            return
        }

        copyToPasteboard(path)
    }

    @objc private func revealProject(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.project?.root ?? process.project?.cwd
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyContainerProjectPath(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.container?.workingDirectory
        else {
            return
        }

        copyToPasteboard(path)
    }

    @objc private func revealContainerProject(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let path = process.container?.workingDirectory
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyContainerName(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let name = process.container?.name
        else {
            return
        }

        copyToPasteboard(name)
    }

    @objc private func copyGroupProjectPath(_ sender: NSMenuItem) {
        guard
            let group = sender.representedObject as? ProcessGroup,
            let path = group.project?.root ?? group.project?.cwd
        else {
            return
        }

        copyToPasteboard(path)
    }

    @objc private func revealGroupProject(_ sender: NSMenuItem) {
        guard
            let group = sender.representedObject as? ProcessGroup,
            let path = group.project?.root ?? group.project?.cwd
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func killProcess(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ListeningProcess else { return }

        for pid in process.pids {
            Darwin.kill(pid, SIGTERM)
        }

        requestRefresh(force: true)
    }

    @objc private func killProcessGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? ProcessGroup else { return }

        for pid in group.pids {
            Darwin.kill(pid, SIGTERM)
        }

        requestRefresh(force: true)
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        guard
            let process = sender.representedObject as? ListeningProcess,
            let container = process.container
        else {
            return
        }

        stopContainers(ids: [container.id])
    }

    @objc private func stopContainerGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? ProcessGroup else { return }
        stopContainers(ids: group.dockerContainers.map(\.id))
    }

    private func stopContainers(ids: [String]) {
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

    @objc private func toggleShowAllProcesses(_ sender: NSMenuItem) {
        showAllProcesses.toggle()
        rebuildMenu()
    }

    @objc private func refreshNow() {
        requestRefresh(force: true)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }

        ignoredPortsTextView?.string = ignoredPorts.map(String.init).sorted().joined(separator: "\n")
        ignoredCommandsTextView?.string = ignoredCommands.sorted().joined(separator: "\n")
        ignoredTargetsTextView?.string = ignoredTargets.sorted().joined(separator: "\n")

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Port Manager Settings"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let title = NSTextField(labelWithString: "Ignore Rules")
        title.font = .boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: 24, y: 382, width: 240, height: 24)
        contentView.addSubview(title)

        let detail = NSTextField(labelWithString: "One value per line. Matching ports, app commands, projects, and Docker containers are hidden from the menu.")
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 24, y: 350, width: 510, height: 34)
        detail.cell?.wraps = true
        contentView.addSubview(detail)

        let ports = makeSettingsTextView(label: "Ports", frame: NSRect(x: 24, y: 118, width: 120, height: 200), in: contentView)
        let commands = makeSettingsTextView(label: "Apps / commands", frame: NSRect(x: 160, y: 118, width: 170, height: 200), in: contentView)
        let targets = makeSettingsTextView(label: "Projects / containers", frame: NSRect(x: 346, y: 118, width: 188, height: 200), in: contentView)

        ignoredPortsTextView = ports
        ignoredCommandsTextView = commands
        ignoredTargetsTextView = targets

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 454, y: 24, width: 80, height: 32)
        contentView.addSubview(saveButton)

        let resetButton = NSButton(title: "Clear All", target: self, action: #selector(clearSettings))
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: 360, y: 24, width: 82, height: 32)
        contentView.addSubview(resetButton)

        return window
    }

    private func makeSettingsTextView(label: String, frame: NSRect, in contentView: NSView) -> NSTextView {
        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: frame.minX, y: frame.maxY + 8, width: frame.width, height: 18)
        contentView.addSubview(labelField)

        let scrollView = NSScrollView(frame: frame)
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        contentView.addSubview(scrollView)
        return textView
    }

    @objc private func saveSettings() {
        ignoredPorts = Set(parseSettingsList(ignoredPortsTextView?.string ?? "").compactMap(Int.init))
        ignoredCommands = Set(parseSettingsList(ignoredCommandsTextView?.string ?? "").map { $0.lowercased() })
        ignoredTargets = Set(parseSettingsList(ignoredTargetsTextView?.string ?? "").map { $0.lowercased() })
        settingsWindow?.close()
        rebuildMenu()
    }

    @objc private func clearSettings() {
        ignoredPorts = []
        ignoredCommands = []
        ignoredTargets = []
        ignoredPortsTextView?.string = ""
        ignoredCommandsTextView?.string = ""
        ignoredTargetsTextView?.string = ""
        rebuildMenu()
    }

    private func parseSettingsList(_ string: String) -> [String] {
        string
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
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

    @objc private func showAbout() {
        let panel = NSAlert()
        panel.messageText = "Port Manager"
        panel.informativeText = "A small menu bar app for finding and killing local listening ports."
        panel.alertStyle = .informational
        panel.addButton(withTitle: "OK")
        panel.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var openAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func localURL(for process: ListeningProcess) -> URL {
        URL(string: "http://localhost:\(process.port)")!
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func devCommand(for path: String) -> String? {
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

    private func packageManagerCommand(for path: String) -> String {
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

    private func launchProcess(executable: String, arguments: [String]) {
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

    private func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func localIPAddressValue() -> String? {
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
} else {
    let app = NSApplication.shared
    let delegate = PortManagerApp()
    app.delegate = delegate
    app.run()
}
