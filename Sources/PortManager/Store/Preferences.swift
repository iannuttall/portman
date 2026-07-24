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

    static var healthProbeEnabled: Bool {
        get { defaults.object(forKey: Key.healthProbeEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.healthProbeEnabled) }
    }

    static var previewsEnabled: Bool {
        get { defaults.object(forKey: Key.previewsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.previewsEnabled) }
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

    func matches(_ entry: ServerEntry) -> Bool {
        switch self {
        case .all: return true
        case .dev: return entry.kind == .dev
        case .docker: return entry.kind == .docker
        case .system: return entry.kind == .system || entry.kind == .database
        case .issues: return entry.hasIssue
        }
    }
}
