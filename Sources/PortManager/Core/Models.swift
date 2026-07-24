import Foundation

// MARK: - Kind

/// Broad category of a listener, used for filter chips and section grouping.
enum ServerKind: String, Codable, Sendable, Hashable, CaseIterable {
    case dev
    case docker
    case database
    case system
    case other

    var label: String {
        switch self {
        case .dev: return "Dev"
        case .docker: return "Docker"
        case .database: return "Database"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .dev: return "hammer"
        case .docker: return "shippingbox"
        case .database: return "cylinder.split.1x2"
        case .system: return "gearshape"
        case .other: return "circle.dotted"
        }
    }
}

/// Whether the project behind a listener still exists on disk.
enum EntryState: String, Codable, Sendable, Hashable {
    case active
    case orphan
    case staleWorktree
}

// MARK: - Metrics

enum EnergyLevel: String, Codable, Sendable, Hashable, Comparable {
    case low
    case medium
    case high

    private var order: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: EnergyLevel, rhs: EnergyLevel) -> Bool {
        lhs.order < rhs.order
    }

    var label: String { rawValue }
}

/// A point-in-time reading for one process, sampled through libproc.
///
/// Every field is optional on purpose: processes owned by another user (or by root)
/// reject `proc_pidinfo`, and a missing reading must render as `—` rather than zero.
struct ProcessSample: Codable, Sendable, Hashable {
    var cpuPercent: Double?
    var residentBytes: UInt64?
    var threads: Int?
    var startedAt: Date?
    var energyLevel: EnergyLevel?

    var uptime: TimeInterval? {
        startedAt.map { Date().timeIntervalSince($0) }
    }

    var isEmpty: Bool {
        cpuPercent == nil && residentBytes == nil && threads == nil && startedAt == nil
    }
}

// MARK: - Health

enum HealthState: String, Codable, Sendable, Hashable {
    /// Not probed yet.
    case unknown
    /// Probe in flight.
    case probing
    /// Answered an HTTP request.
    case healthy
    /// Socket accepted the connection but nothing came back before the timeout.
    /// This is the "process is alive but the server is wedged" case.
    case hung
    /// Speaks something that isn't HTTP — Postgres, Redis, a raw TCP service.
    case nonHTTP
    /// Connection refused between the scan and the probe; the process is going away.
    case refused
}

struct HealthReport: Codable, Sendable, Hashable {
    var state: HealthState = .unknown
    var statusCode: Int?
    var latency: TimeInterval?
    var pageTitle: String?
    var serverHeader: String?
    var scheme: String = "http"
    var checkedAt: Date?

    static let unknown = HealthReport()

    var isServingHTTP: Bool {
        state == .healthy
    }
}

// MARK: - Git

struct GitStatus: Codable, Sendable, Hashable {
    var branch: String?
    var dirtyCount: Int?
    var isWorktree: Bool = false
    var isDetached: Bool = false

    var isClean: Bool {
        (dirtyCount ?? 0) == 0
    }
}

// MARK: - Project

struct ProjectMetadata: Codable, Hashable, Sendable {
    let cwd: String?
    let root: String?
    let name: String
    let framework: String?
    let frameworkVersion: String?
    let isOrphan: Bool
    let isStaleWorktree: Bool

    init(
        cwd: String?,
        root: String?,
        name: String,
        framework: String?,
        frameworkVersion: String? = nil,
        isOrphan: Bool,
        isStaleWorktree: Bool
    ) {
        self.cwd = cwd
        self.root = root
        self.name = name
        self.framework = framework
        self.frameworkVersion = frameworkVersion
        self.isOrphan = isOrphan
        self.isStaleWorktree = isStaleWorktree
    }

    var path: String? {
        root ?? cwd
    }

    var displayPath: String? {
        guard let path else { return nil }
        return path.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~",
            options: [.anchored]
        )
    }

    /// `Astro 5.2` when we know the version, `Astro` when we only know the framework.
    var frameworkLabel: String? {
        guard let framework else { return nil }
        guard let frameworkVersion else { return framework }
        return "\(framework) \(frameworkVersion)"
    }
}

// MARK: - Docker

struct DockerContainer: Codable, Hashable, Sendable {
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

    var displayPath: String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return workingDirectory.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~",
            options: [.anchored]
        )
    }

    /// `8080 → 80` when Docker forwards to a different container port.
    var portMappingLabel: String {
        guard let containerPort, containerPort != hostPort else { return "\(hostPort)" }
        return "\(hostPort) → \(containerPort)"
    }
}

// MARK: - Raw scan output

/// One `(pid, command, user, ports)` tuple as parsed straight out of `lsof`.
struct ProcessSnapshot: Sendable {
    var pid: Int32 = 0
    var command = ""
    var user = ""
    var ports: [Int: Set<String>] = [:]
}

// MARK: - Entry

/// A single listener, enriched as the pipeline learns more about it.
///
/// The scan produces the immutable half; metrics, health and git arrive later and
/// independently, so the UI can render a useful row before every enricher has finished.
struct ServerEntry: Identifiable, Codable, Hashable, Sendable {
    // Scan output
    let port: Int
    let pids: [Int32]
    let command: String
    let user: String
    let addresses: [String]
    let project: ProjectMetadata?
    let container: DockerContainer?

    // Enrichment
    var metrics: ProcessSample?
    var health: HealthReport?
    var git: GitStatus?

    init(
        port: Int,
        pids: [Int32],
        command: String,
        user: String,
        addresses: [String],
        project: ProjectMetadata? = nil,
        container: DockerContainer? = nil,
        metrics: ProcessSample? = nil,
        health: HealthReport? = nil,
        git: GitStatus? = nil
    ) {
        self.port = port
        self.pids = pids
        self.command = command
        self.user = user
        self.addresses = addresses
        self.project = project
        self.container = container
        self.metrics = metrics
        self.health = health
        self.git = git
    }

    /// Stable across scans so SwiftUI animates rows instead of replacing them.
    /// A restarted server gets a new pid, and a new identity, which is what we want.
    var id: String {
        "\(port):\(primaryPID ?? 0)"
    }

    var primaryPID: Int32? {
        pids.min()
    }

    // MARK: Classification

    var kind: ServerKind {
        if container != nil { return .docker }
        if project != nil { return .dev }
        if Self.databaseCommands.contains(where: { command.lowercased().contains($0) }) {
            return .database
        }
        if isSystemProcess { return .system }
        return .other
    }

    var state: EntryState {
        guard let project else { return .active }
        if project.isStaleWorktree { return .staleWorktree }
        if project.isOrphan { return .orphan }
        return .active
    }

    var hasIssue: Bool {
        state != .active || health?.state == .hung
    }

    private var isSystemProcess: Bool {
        if port < 1024 { return true }
        return Self.systemCommands.contains(command.lowercased())
    }

    /// Hidden unless "Show System Ports" is on. Docker and orphans always stay visible —
    /// an orphan on a low port is exactly the thing worth surfacing.
    var hiddenByDefault: Bool {
        if container != nil { return false }
        if project?.isOrphan == true { return false }
        return isSystemProcess
    }

    /// Debug/HMR sidecar ports that shouldn't compete with a project's real app port.
    var isLikelyHelperPort: Bool {
        if port >= 9229 && port <= 9329 { return true }
        if port >= 49152 { return true }
        return false
    }

    // MARK: Display

    /// The bold half of a row: the project, container, or app name.
    var title: String {
        if let container { return container.displayName }
        if let project { return project.name }
        return prettyCommand
    }

    /// The dimmer qualifier next to the title — framework, image, or nothing.
    var subtitle: String? {
        if let container { return container.image }
        if let project { return project.frameworkLabel ?? prettyCommand }
        return nil
    }

    var badge: String? {
        if container != nil { return "Docker" }
        return project?.frameworkLabel
    }

    var displayPath: String? {
        container?.displayPath ?? project?.displayPath
    }

    var path: String? {
        container?.workingDirectory ?? project?.path
    }

    var prettyCommand: String {
        let lower = command.lowercased()

        for (needle, pretty) in Self.commandDisplayNames where lower.contains(needle) {
            return pretty
        }

        return command.prefix(1).uppercased() + command.dropFirst()
    }

    /// Single-line form, kept for the `--list` CLI output only. The panel composes
    /// its own layout from the structured fields above.
    var singleLineDescription: String {
        var parts = ["\(port)"]
        if state == .staleWorktree { parts.append("Stale Worktree") }
        if state == .orphan { parts.append("Orphan") }
        if let subtitle { parts.append(subtitle) }
        parts.append(title)
        return parts.joined(separator: " · ")
    }

    // MARK: Pins and ignores

    /// Groups every port of one project or container under a single pin.
    var pinKey: String {
        if let container {
            return "docker:\(container.composeProject ?? ""):\(container.composeService ?? ""):\(container.name)"
        }

        if let project {
            return "project:\(project.path ?? project.name)"
        }

        return "process:\(command):\(port)"
    }

    var pinNoun: String {
        if container != nil { return "Container" }
        if project != nil { return "Project" }
        return "Port"
    }

    var ignoreTargetKey: String? {
        if let container {
            return (container.composeProject.map { "\($0)/\(container.composeService ?? container.name)" } ?? container.name)
                .lowercased()
        }

        if let project {
            return (project.path ?? project.name).lowercased()
        }

        return nil
    }

    // MARK: Tables

    private static let commandDisplayNames: [(String, String)] = [
        ("node", "Node"),
        ("bun", "Bun"),
        ("deno", "Deno"),
        ("python", "Python"),
        ("ruby", "Ruby"),
        ("httpd", "httpd"),
        ("nginx", "nginx"),
        ("caddy", "Caddy"),
        ("postgres", "Postgres"),
        ("mysqld", "MySQL"),
        ("mongod", "MongoDB"),
        ("redis", "Redis"),
        ("php", "PHP"),
        ("java", "Java"),
        ("dotnet", ".NET")
    ]

    private static let databaseCommands: Set<String> = [
        "postgres", "mysqld", "mariadb", "mongod", "redis", "memcached",
        "elasticsearch", "clickhouse", "influxd", "cockroach", "surreal"
    ]

    private static let systemCommands: Set<String> = [
        "controlcenter", "rapportd", "raycast", "ollama", "sharingd",
        "remoted", "airplayxpchelper", "identityservicesd", "apsd",
        "nsurlsessiond", "trustd", "syncdefaultsd", "cloudd"
    ]
}
