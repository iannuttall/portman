import AppKit
import Darwin
import Foundation
import SwiftUI

/// Owns the server list and everything the panel does to it.
///
/// Scanning and enrichment run off the main actor; only the resulting state lands
/// here. The panel reads derived values (`sections`, `conflictPorts`) rather than
/// filtering inline, so the list shape is testable without a view.
@MainActor
@Observable
final class ServerStore {
    static let shared = ServerStore()

    // MARK: State

    private(set) var entries: [ServerEntry] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var networkAddress: String?
    private(set) var isWarmStart = false

    var searchText = "" {
        didSet { clampSelection() }
    }

    var filter: EntryFilter = .all {
        didSet { clampSelection() }
    }

    var sortOrder: SortOrder = Preferences.sortOrder {
        didSet { Preferences.sortOrder = sortOrder }
    }

    var groupMode: GroupMode = Preferences.groupMode {
        didSet { Preferences.groupMode = groupMode }
    }

    var showAllProcesses: Bool = Preferences.showAllProcesses {
        didSet {
            Preferences.showAllProcesses = showAllProcesses
            clampSelection()
        }
    }

    var selectedRowID: String?
    var expandedRowID: String?

    /// A bulk kill waiting on confirmation.
    var pendingKill: PendingKill?
    /// Transient footer message when an action didn't do what the UI implied.
    var actionMessage: String?

    // MARK: Collaborators

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private let sampler = ProcessMetricsSampler()
    @ObservationIgnored private let gitInspector = GitInspector()
    @ObservationIgnored private let healthProbe = HealthProbe()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPanelOpen = false

    /// Ports killed in the last few seconds. Suppresses the row until the next
    /// scan confirms it, so a killed server doesn't flicker back into the list.
    @ObservationIgnored private var recentlyKilled: [Int: Date] = [:]

    private static let openInterval: TimeInterval = 2
    private static let killGracePeriod: TimeInterval = 6

    private init() {
        entries = SnapshotCache.load()
        isWarmStart = !entries.isEmpty
        observeSleepWake()
    }

    // MARK: - Derived list

    var visibleEntries: [ServerEntry] {
        entries
            .filter { !isIgnored($0) }
            .filter { showAllProcesses || !$0.hiddenByDefault }
            .filter { !recentlyKilled.keys.contains($0.port) }
            .filter { filter.matches($0) }
            .filter { ListShaper.matches($0, query: searchText) }
    }

    var sections: [ServerSection] {
        ListShaper.sections(
            for: visibleEntries,
            pinnedKeys: Preferences.pinnedKeys,
            mode: groupMode,
            order: sortOrder
        )
    }

    var rows: [ServerRowModel] {
        sections.flatMap(\.rows)
    }

    var conflictPorts: Set<Int> {
        ListShaper.conflictPorts(in: entries.filter { !isIgnored($0) })
    }

    /// Everything currently listed, for "kill all matching".
    var matchingPIDs: [Int32] {
        Array(Set(rows.flatMap(\.allPIDs))).sorted()
    }

    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all
    }

    var badgeCount: Int {
        entries
            .filter { !isIgnored($0) }
            .filter { showAllProcesses || !$0.hiddenByDefault }
            .count
    }

    var hasIssues: Bool {
        visibleEntries.contains { $0.hasIssue }
    }

    // MARK: - Ignore rules

    func isIgnored(_ entry: ServerEntry) -> Bool {
        if Preferences.ignoredPorts.contains(entry.port) { return true }

        let command = entry.command.lowercased()
        let pretty = entry.prettyCommand.lowercased()
        if Preferences.ignoredCommands.contains(where: { command.contains($0) || pretty.contains($0) }) {
            return true
        }

        guard let target = entry.ignoreTargetKey else { return false }
        return Preferences.ignoredTargets.contains { target.contains($0) }
    }

    // MARK: - Polling

    func start() {
        refresh(force: true)
        scheduleTimer()
    }

    func panelDidOpen() {
        isPanelOpen = true
        scheduleTimer()
        refresh()
    }

    func panelDidClose() {
        isPanelOpen = false
        searchText = ""
        expandedRowID = nil
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()

        let interval = isPanelOpen ? Self.openInterval : Preferences.refreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.suspend()
            }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                // Give the network stack a moment before scanning again.
                try? await Task.sleep(for: .seconds(1.5))
                self?.start()
            }
        }
    }

    private func suspend() {
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Scanning

    func refresh(force: Bool = false) {
        if isScanning && !force { return }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }

            isScanning = true
            defer { isScanning = false }

            let scanner = self.scanner
            let scanned = await Task.detached(priority: .utility) {
                (
                    entries: scanner.scan(),
                    address: AppLauncher.localIPAddress()
                )
            }.value

            guard !Task.isCancelled else { return }

            networkAddress = scanned.address
            await applyScan(scanned.entries)
        }
    }

    private func applyScan(_ scanned: [ServerEntry]) async {
        var enriched = scanned

        // Metrics for everything, since sorting by CPU needs the whole list.
        let pids = Array(Set(enriched.flatMap(\.pids)))
        let samples = await sampler.sample(pids: pids)

        // Git only for projects that still exist on disk.
        var gitByRoot: [String: GitStatus] = [:]
        let roots = Set(enriched.compactMap { entry -> String? in
            guard entry.state != .staleWorktree, let path = entry.project?.path else { return nil }
            return path
        })

        for root in roots {
            if let status = await gitInspector.status(forRoot: root) {
                gitByRoot[root] = status
            }
        }

        for index in enriched.indices {
            if let pid = enriched[index].primaryPID {
                enriched[index].metrics = samples[pid]
            }

            if let root = enriched[index].project?.path {
                enriched[index].git = gitByRoot[root]
            }
        }

        pruneRecentlyKilled()
        commit(enriched)

        // Health probes run after the list is on screen — a wedged server takes
        // the full timeout to detect, and the list must not wait for it.
        if Preferences.healthProbeEnabled {
            await probeHealth(for: enriched)
        }
    }

    private func probeHealth(for enriched: [ServerEntry]) async {
        let probeable = enriched.filter { $0.kind != .system && $0.kind != .database }
        guard !probeable.isEmpty else { return }

        let reports = await healthProbe.probe(ports: probeable.map(\.port))
        guard !Task.isCancelled, !reports.isEmpty else { return }

        var updated = entries
        for index in updated.indices {
            if let report = reports[updated[index].port] {
                updated[index].health = report
            }
        }

        commit(updated)
    }

    private func commit(_ updated: [ServerEntry]) {
        withAnimation(Theme.Motion.listUpdate) {
            entries = updated
        }

        lastScan = Date()
        isWarmStart = false
        clampSelection()
        SnapshotCache.save(updated)
    }

    // MARK: - Selection

    private func clampSelection() {
        let ids = Set(rows.map(\.id))

        if let selectedRowID, !ids.contains(selectedRowID) {
            self.selectedRowID = rows.first?.id
        }

        if let expandedRowID, !ids.contains(expandedRowID) {
            self.expandedRowID = nil
        }
    }

    func selectFirst() {
        selectedRowID = rows.first?.id
    }

    func moveSelection(by offset: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }

        guard let current = selectedRowID, let index = ids.firstIndex(of: current) else {
            selectedRowID = ids.first
            return
        }

        let next = min(max(index + offset, 0), ids.count - 1)
        selectedRowID = ids[next]
    }

    func toggleExpanded(_ id: String) {
        withAnimation(Theme.Motion.expand) {
            expandedRowID = expandedRowID == id ? nil : id
        }
    }

    var selectedRow: ServerRowModel? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }
    }

    // MARK: - Actions

    func url(for entry: ServerEntry) -> URL {
        let scheme = entry.health?.scheme ?? "http"
        return URL(string: "\(scheme)://localhost:\(entry.port)") ?? URL(fileURLWithPath: "/")
    }

    func networkURL(for entry: ServerEntry) -> String? {
        guard let networkAddress else { return nil }
        let scheme = entry.health?.scheme ?? "http"
        return "\(scheme)://\(networkAddress):\(entry.port)"
    }

    func open(_ entry: ServerEntry) {
        AppLauncher.openInBrowser(url(for: entry), bundleID: Preferences.browserBundleID)
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func kill(_ row: ServerRowModel) {
        if let container = row.entry.container {
            stopContainers([container.id])
            return
        }

        signal(pids: row.allPIDs)
        suppress(ports: [row.entry.port] + row.related.map(\.port))
    }

    /// Bulk kills ask first. A single row is cheap to restart; wiping out every server
    /// behind a filter is not, and there is no undo for it.
    struct PendingKill: Identifiable {
        let id = UUID()
        let rows: [ServerRowModel]
        let title: String
    }

    func requestKill(rows targets: [ServerRowModel], title: String) {
        guard !targets.isEmpty else { return }
        pendingKill = PendingKill(rows: targets, title: title)
    }

    func confirmPendingKill() {
        guard let pendingKill else { return }
        self.pendingKill = nil
        kill(rows: pendingKill.rows)
    }

    func cancelPendingKill() {
        pendingKill = nil
    }

    func kill(rows targets: [ServerRowModel]) {
        let containerIDs = targets.compactMap { $0.entry.container?.id }
        if !containerIDs.isEmpty {
            stopContainers(containerIDs)
        }

        let pids = targets.filter { $0.entry.container == nil }.flatMap(\.allPIDs)
        signal(pids: Array(Set(pids)).sorted())
        suppress(ports: targets.flatMap { [$0.entry.port] + $0.related.map(\.port) })
    }

    /// Sends SIGTERM and reports what actually happened.
    ///
    /// `kill(2)` fails with EPERM for processes owned by root or another user, and the
    /// row animating away regardless would be a lie — the server is still there, and it
    /// reappears on the next scan with no explanation.
    private func signal(pids: [Int32]) {
        var denied = 0

        for pid in pids where Darwin.kill(pid, SIGTERM) != 0 {
            if errno == EPERM { denied += 1 }
        }

        if denied > 0 {
            actionMessage = denied == 1
                ? "Couldn't kill that process — it belongs to another user."
                : "Couldn't kill \(denied) processes — they belong to another user."
            clearActionMessageLater()
        }

        refresh(force: true)
    }

    private func clearActionMessageLater() {
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.actionMessage = nil
        }
    }

    private func suppress(ports: [Int]) {
        let now = Date()
        for port in ports {
            recentlyKilled[port] = now
        }

        withAnimation(Theme.Motion.kill) {
            // Recomputing derived state is enough — visibleEntries filters these out.
            entries = entries
        }
    }

    private func pruneRecentlyKilled() {
        let cutoff = Date().addingTimeInterval(-Self.killGracePeriod)
        recentlyKilled = recentlyKilled.filter { $0.value > cutoff }
    }

    private func stopContainers(_ ids: [String]) {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return }

        Task { [weak self] in
            await Task.detached(priority: .utility) {
                DockerScanner.stop(containerIDs: unique)
            }.value

            self?.refresh(force: true)
        }
    }

    func restart(_ row: ServerRowModel) {
        guard
            let path = row.entry.path,
            let command = AppLauncher.devCommand(for: path)
        else {
            return
        }

        signal(pids: row.allPIDs)
        AppLauncher.runCommand(command, in: path, bundleID: Preferences.terminalBundleID)
    }

    func canRestart(_ row: ServerRowModel) -> Bool {
        guard let path = row.entry.path else { return false }
        return AppLauncher.devCommand(for: path) != nil
    }

    // MARK: - Pins and ignores

    func isPinned(_ entry: ServerEntry) -> Bool {
        Preferences.pinnedKeys.contains(entry.pinKey)
    }

    func togglePin(_ entry: ServerEntry) {
        var keys = Preferences.pinnedKeys
        if keys.contains(entry.pinKey) {
            keys.remove(entry.pinKey)
        } else {
            keys.insert(entry.pinKey)
        }

        Preferences.pinnedKeys = keys
        withAnimation(Theme.Motion.listUpdate) { entries = entries }
    }

    func ignorePort(_ entry: ServerEntry) {
        var ports = Preferences.ignoredPorts
        ports.insert(entry.port)
        Preferences.ignoredPorts = ports
        refreshDerived()
    }

    func ignoreTarget(_ entry: ServerEntry) {
        guard let target = entry.ignoreTargetKey else {
            var commands = Preferences.ignoredCommands
            commands.insert(entry.command.lowercased())
            Preferences.ignoredCommands = commands
            refreshDerived()
            return
        }

        var targets = Preferences.ignoredTargets
        targets.insert(target)
        Preferences.ignoredTargets = targets
        refreshDerived()
    }

    private func refreshDerived() {
        withAnimation(Theme.Motion.listUpdate) { entries = entries }
    }
}

// MARK: - Warm start

/// Persists the last scan so the panel paints instantly on open instead of
/// showing an empty box while `lsof` runs.
enum SnapshotCache {
    private static var url: URL? {
        guard
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            return nil
        }

        let directory = base.appendingPathComponent("app.local.portmanager", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("snapshot.json")
    }

    static func load() -> [ServerEntry] {
        guard
            let url,
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([ServerEntry].self, from: data)
        else {
            return []
        }

        return entries
    }

    static func save(_ entries: [ServerEntry]) {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
