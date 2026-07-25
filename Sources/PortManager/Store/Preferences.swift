import Foundation

/// Everything the app remembers between launches.
///
/// The pin and ignore keys match the previous release exactly, so upgrading
/// doesn't silently drop someone's configuration.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    // MARK: Keys

    private enum Key {
        static let showAllProcesses = "showAllProcesses"
        static let pinnedKeys = "pinnedKeys"
        static let ignoredPorts = "ignoredPorts"
        static let ignoredCommands = "ignoredCommands"
        static let ignoredTargets = "ignoredTargets"
        static let refreshInterval = "refreshInterval"
        static let terminalBundleID = "terminalBundleID"
        static let editorBundleID = "editorBundleID"
        static let browserBundleID = "browserBundleID"
        static let sortOrder = "sortOrder"
        static let groupMode = "groupMode"
        static let menuBarMode = "menuBarMode"
        static let healthProbeEnabled = "healthProbeEnabled"
        static let previewsEnabled = "previewsEnabled"
        static let showSparklines = "showSparklines"
        static let showGitBranch = "showGitBranch"
        static let showMetrics = "showMetrics"
        static let showPageTitles = "showPageTitles"
        static let reduceMotion = "reduceMotion"
        static let rowDensity = "rowDensity"
        static let cloudflaredPath = "cloudflaredPath"
        static let rewriteTunnelHost = "rewriteTunnelHost"
    }

    // MARK: Visibility

    static var showAllProcesses: Bool {
        get { defaults.bool(forKey: Key.showAllProcesses) }
        set { defaults.set(newValue, forKey: Key.showAllProcesses) }
    }

    static var pinnedKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.pinnedKeys) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.pinnedKeys) }
    }

    static var ignoredPorts: Set<Int> {
        get { Set(defaults.stringArray(forKey: Key.ignoredPorts)?.compactMap(Int.init) ?? []) }
        set { defaults.set(newValue.map(String.init).sorted(), forKey: Key.ignoredPorts) }
    }

    static var ignoredCommands: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.ignoredCommands) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.ignoredCommands) }
    }

    static var ignoredTargets: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.ignoredTargets) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.ignoredTargets) }
    }

    // MARK: Scanning

    /// Seconds between scans while the panel is closed. The panel polls faster
    /// on its own while it's open.
    static var refreshInterval: Double {
        get {
            let stored = defaults.double(forKey: Key.refreshInterval)
            return stored > 0 ? stored : 15
        }
        set { defaults.set(newValue, forKey: Key.refreshInterval) }
    }

    /// Each port is checked once when it first appears, not on every scan — repeated
    /// probing was what made the list flicker.
    static var healthProbeEnabled: Bool {
        get { defaults.object(forKey: Key.healthProbeEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.healthProbeEnabled) }
    }

    static var previewsEnabled: Bool {
        get { defaults.object(forKey: Key.previewsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.previewsEnabled) }
    }

    // MARK: Row content

    static var showMetrics: Bool {
        get { defaults.object(forKey: Key.showMetrics) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showMetrics) }
    }

    static var showSparklines: Bool {
        get { defaults.object(forKey: Key.showSparklines) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showSparklines) }
    }

    static var showGitBranch: Bool {
        get { defaults.object(forKey: Key.showGitBranch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showGitBranch) }
    }

    static var showPageTitles: Bool {
        get { defaults.object(forKey: Key.showPageTitles) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showPageTitles) }
    }

    /// How much each row shows. Simple is the default: the detail is all still
    /// there, one click down, rather than on screen at all times.
    static var rowDensity: RowDensity {
        get { RowDensity(rawValue: defaults.string(forKey: Key.rowDensity) ?? "") ?? .simple }
        set { defaults.set(newValue.rawValue, forKey: Key.rowDensity) }
    }

    /// Turns off list animations. The list still updates — it just doesn't move
    /// while you're reading it.
    static var reduceMotion: Bool {
        get { defaults.object(forKey: Key.reduceMotion) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.reduceMotion) }
    }

    // MARK: External apps

    static var terminalBundleID: String? {
        get {
            defaults.string(forKey: Key.terminalBundleID)
                ?? AppLauncher.installed(.terminal).first?.id
        }
        set { defaults.set(newValue, forKey: Key.terminalBundleID) }
    }

    static var editorBundleID: String? {
        get {
            defaults.string(forKey: Key.editorBundleID)
                ?? AppLauncher.installed(.editor).first?.id
        }
        set { defaults.set(newValue, forKey: Key.editorBundleID) }
    }

    /// Sends `Host: localhost:<port>` to the local server instead of the
    /// `*.trycloudflare.com` hostname.
    ///
    /// On by default because without it most dev servers reject the request outright:
    /// Vite answers "This host is not allowed", and Next and Astro have equivalent
    /// checks. Turn it off if the app builds absolute URLs from the Host header and
    /// you need those to be the public hostname.
    static var rewriteTunnelHost: Bool {
        get { defaults.object(forKey: Key.rewriteTunnelHost) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.rewriteTunnelHost) }
    }

    /// Overrides the search paths when cloudflared lives somewhere unusual.
    static var cloudflaredPath: String? {
        get { defaults.string(forKey: Key.cloudflaredPath) }
        set { defaults.set(newValue, forKey: Key.cloudflaredPath) }
    }

    /// nil means "whatever the system default browser is".
    static var browserBundleID: String? {
        get { defaults.string(forKey: Key.browserBundleID) }
        set { defaults.set(newValue, forKey: Key.browserBundleID) }
    }

    // MARK: View state

    static var sortOrder: SortOrder {
        get { SortOrder(rawValue: defaults.string(forKey: Key.sortOrder) ?? "") ?? .port }
        set { defaults.set(newValue.rawValue, forKey: Key.sortOrder) }
    }

    static var groupMode: GroupMode {
        get { GroupMode(rawValue: defaults.string(forKey: Key.groupMode) ?? "") ?? .smart }
        set { defaults.set(newValue.rawValue, forKey: Key.groupMode) }
    }

    static var menuBarMode: MenuBarMode {
        get { MenuBarMode(rawValue: defaults.string(forKey: Key.menuBarMode) ?? "") ?? .iconAndCount }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarMode) }
    }
}

// MARK: - View state types

enum SortOrder: String, CaseIterable, Sendable {
    case port
    case name
    case cpu
    case memory
    case uptime
    case recentlyStarted

    var label: String {
        switch self {
        case .port: return "Port"
        case .name: return "Name"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .uptime: return "Uptime"
        case .recentlyStarted: return "Recently started"
        }
    }
}

enum GroupMode: String, CaseIterable, Sendable {
    /// Sections only where they earn their keep: pinned, conflicts, stale worktrees.
    case smart
    case none
    case project
    case kind

    var label: String {
        switch self {
        case .smart: return "Smart"
        case .none: return "Flat"
        case .project: return "By project"
        case .kind: return "By kind"
        }
    }
}

enum RowDensity: String, CaseIterable, Sendable {
    /// Port, name, framework, and anything that's wrong. Nothing else.
    case simple
    /// Adds branch, CPU, CPU history, uptime and page title.
    case detailed

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .detailed: return "Detailed"
        }
    }

    var explanation: String {
        switch self {
        case .simple: return "Port, project, framework, and anything that needs attention."
        case .detailed: return "Adds git branch, CPU, uptime and page title to every row."
        }
    }
}

enum MenuBarMode: String, CaseIterable, Sendable {
    case iconOnly
    case iconAndCount
    case countOnly

    var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .iconAndCount: return "Icon and count"
        case .countOnly: return "Count only"
        }
    }
}

enum EntryFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case dev
    case docker
    case system
    case issues

    var label: String {
        switch self {
        case .all: return "All"
        case .dev: return "Dev"
        case .docker: return "Docker"
        case .system: return "System"
        case .issues: return "Issues"
        }
    }

    /// A conflict is a property of the pair, not of either row, so the contested
    /// ports have to be passed in — an entry can't tell on its own.
    func matches(_ entry: ServerEntry, contestedPorts: Set<Int> = []) -> Bool {
        switch self {
        case .all: return true
        case .dev: return entry.kind == .dev
        case .docker: return entry.kind == .docker
        case .system: return entry.kind == .system || entry.kind == .database
        case .issues: return entry.hasIssue || contestedPorts.contains(entry.port)
        }
    }
}
