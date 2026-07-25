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
        didSet { inputsChanged() }
    }

    var filter: EntryFilter = .all {
        didSet { inputsChanged() }
    }

    var sortOrder: SortOrder = Preferences.sortOrder {
        didSet {
            Preferences.sortOrder = sortOrder
            inputsChanged()
        }
    }

    var groupMode: GroupMode = Preferences.groupMode {
        didSet {
            Preferences.groupMode = groupMode
            inputsChanged()
        }
    }

    var showAllProcesses: Bool = Preferences.showAllProcesses {
        didSet {
            Preferences.showAllProcesses = showAllProcesses
            inputsChanged()
        }
    }

    // Display preferences live here rather than being read from UserDefaults inside
    // view bodies, so toggling one updates the panel immediately.

    var rowDensity: RowDensity = Preferences.rowDensity {
        didSet { Preferences.rowDensity = rowDensity }
    }

    var showMetrics: Bool = Preferences.showMetrics {
        didSet { Preferences.showMetrics = showMetrics }
    }

    var showSparklines: Bool = Preferences.showSparklines {
        didSet { Preferences.showSparklines = showSparklines }
    }

    var showGitBranch: Bool = Preferences.showGitBranch {
        didSet { Preferences.showGitBranch = showGitBranch }
    }

    var showPageTitles: Bool = Preferences.showPageTitles {
        didSet { Preferences.showPageTitles = showPageTitles }
    }

    var previewsEnabled: Bool = Preferences.previewsEnabled {
        didSet { Preferences.previewsEnabled = previewsEnabled }
    }

    var healthProbeEnabled: Bool = Preferences.healthProbeEnabled {
        didSet { Preferences.healthProbeEnabled = healthProbeEnabled }
    }

    var reduceMotion: Bool = Preferences.reduceMotion {
        didSet { Preferences.reduceMotion = reduceMotion }
    }

    /// nil disables the animation entirely.
    func animation(_ base: Animation) -> Animation? {
        reduceMotion ? nil : base
    }

    var selectedRowID: String?
    var expandedRowID: String?

    /// An action waiting on confirmation.
    var pendingConfirmation: PendingConfirmation?
    /// Public tunnels, keyed by port.
    var tunnels: [Int: TunnelInfo] = [:]
    /// Transient footer message when an action didn't do what the UI implied.
    var actionMessage: String?

    // MARK: Collaborators

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private let sampler = ProcessMetricsSampler()
    @ObservationIgnored private let gitInspector = GitInspector()
    @ObservationIgnored private let healthProbe = HealthProbe()
    @ObservationIgnored private let tunnelService = TunnelService()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPanelOpen = false

    /// Ports killed in the last few seconds. Suppresses the row until the next
    /// scan confirms it, so a killed server doesn't flicker back into the list.
    @ObservationIgnored private var recentlyKilled: [Int: Date] = [:]

    /// Health results, kept by port across scans.
    ///
    /// A scan produces entries with no health, so without this the probe would run
    /// again every cycle — which is exactly what made the list flicker. A port is
    /// checked once when it first appears, and again only on an explicit refresh.
    @ObservationIgnored private var healthByPort: [Int: HealthReport] = [:]

    private static let openInterval: TimeInterval = 2
    private static let killGracePeriod: TimeInterval = 6

    private init() {
        entries = SnapshotCache.load()
        isWarmStart = !entries.isEmpty
        rebuildDerived()
        observeSleepWake()
    }

    // MARK: - Derived list

    /// Everything the panel could show, before the filter chips and search.
    var candidateEntries: [ServerEntry] {
        entries
            .filter { !isIgnored($0) }
            .filter { showAllProcesses || !$0.hiddenByDefault }
            .filter { !recentlyKilled.keys.contains($0.port) }
    }

    var visibleEntries: [ServerEntry] {
        let base = candidateEntries
        let contested = ListShaper.conflictPorts(in: base)

        return base
            .filter { filter.matches($0, contestedPorts: contested) }
            .filter { ListShaper.matches($0, query: searchText) }
    }

    /// Count behind each filter chip. Lives here so the chips and the list can't
    /// disagree about what a filter means.
    func count(for filter: EntryFilter) -> Int? {
        guard filter != .all else { return nil }

        let base = candidateEntries
        let contested = ListShaper.conflictPorts(in: base)
        let matching = base.filter { filter.matches($0, contestedPorts: contested) }.count

        return matching > 0 ? matching : nil
    }

    /// Derived list state, rebuilt when its inputs change rather than on every
    /// render pass.
    ///
    /// These were computed properties. `conflictPorts` in particular was read once
    /// per row inside the list body, so the whole folding and conflict pipeline ran
    /// n times per frame over ~30 servers — enough work during a refresh to show up
    /// as the list churning.
    private(set) var sections: [ServerSection] = []
    private(set) var rows: [ServerRowModel] = []
    private(set) var conflictPorts: Set<Int> = []

    func rebuildDerived() {
        let visible = visibleEntries

        sections = ListShaper.sections(
            for: visible,
            pinnedKeys: Preferences.pinnedKeys,
            mode: groupMode,
            order: sortOrder
        )
        rows = sections.flatMap(\.rows)
        conflictPorts = ListShaper.conflictPorts(in: candidateEntries)
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
        let base = candidateEntries
        let contested = ListShaper.conflictPorts(in: base)
        return base.contains { $0.hasIssue || contested.contains($0.port) }
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

        // An explicit refresh re-checks health; the automatic poll does not.
        if force { healthByPort.removeAll() }

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

            enriched[index].health = healthByPort[enriched[index].port]
        }

        pruneRecentlyKilled()
        pruneHealth(keeping: Set(enriched.map(\.port)))
        commit(enriched)

        // Probing runs off the scan cycle, and only for ports we haven't checked yet.
        //
        // Awaiting it here made a scan outlast the 2s poll whenever a few servers
        // were wedged, and re-checking known ports every cycle rewrote the list
        // continuously.
        guard healthProbeEnabled else { return }

        let unchecked = enriched.filter {
            healthByPort[$0.port] == nil && $0.kind != .system && $0.kind != .database
        }

        guard !unchecked.isEmpty else { return }

        probeTask?.cancel()
        probeTask = Task { [weak self] in
            await self?.probe(ports: unchecked.map(\.port))
        }
    }

    /// Re-checks a single port on demand — used when a row is expanded, so the card
    /// shows something current rather than whatever was true when it first appeared.
    func recheckHealth(for entry: ServerEntry) {
        guard healthProbeEnabled else { return }

        Task { [weak self] in
            await self?.healthProbe.invalidate(port: entry.port)
            await self?.probe(ports: [entry.port])
        }
    }

    private func probe(ports: [Int]) async {
        let reports = await healthProbe.probe(ports: ports)
        guard !Task.isCancelled, !reports.isEmpty else { return }

        healthByPort.merge(reports) { _, new in new }

        var updated = entries
        for index in updated.indices {
            if let report = reports[updated[index].port] {
                updated[index].health = report
            }
        }

        guard updated != entries else { return }
        commit(updated)
    }

    // MARK: - CPU history

    /// A short rolling CPU trace per row, so a row can show whether a server is
    /// spiking or idling without the user having to watch the number.
    @ObservationIgnored private var cpuHistory: [String: [Double]] = [:]
    private static let historyLength = 24

    func cpuTrace(for id: String) -> [Double] {
        cpuHistory[id] ?? []
    }

    private func recordCPU(_ entries: [ServerEntry]) {
        var updated: [String: [Double]] = [:]

        for entry in entries {
            guard let cpu = entry.metrics?.cpuPercent else {
                // Keep what we had rather than punching a hole in the trace.
                updated[entry.id] = cpuHistory[entry.id]
                continue
            }

            var trace = cpuHistory[entry.id] ?? []
            trace.append(cpu)
            if trace.count > Self.historyLength {
                trace.removeFirst(trace.count - Self.historyLength)
            }

            updated[entry.id] = trace
        }

        // Entries that went away drop their history with them.
        cpuHistory = updated.compactMapValues { $0 }
    }

    private func commit(_ updated: [ServerEntry]) {
        recordCPU(updated)

        // Only animate when the list actually changes shape. A refresh that just
        // moved a CPU reading must not animate — the panel polls every 2s while
        // open, and animating those made the whole list shimmer while reading it.
        let structureChanged = updated.map(\.id) != entries.map(\.id)

        if structureChanged && !Preferences.reduceMotion {
            withAnimation(Theme.Motion.listUpdate) {
                entries = updated
            }
        } else {
            entries = updated
        }

        lastScan = Date()
        isWarmStart = false
        inputsChanged()
        SnapshotCache.save(updated)
    }

    // MARK: - Selection

    private func inputsChanged() {
        rebuildDerived()
        clampSelection()
    }

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
        withAnimation(animation(Theme.Motion.expand)) {
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

    /// nil when the server is bound to loopback only — offering a network URL that
    /// can't resolve is worse than not offering one.
    func networkURL(for entry: ServerEntry) -> String? {
        guard let networkAddress, entry.exposure == .network else { return nil }
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

    /// Anything with no undo asks first: a bulk kill, or putting a port on the
    /// public internet.
    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let message: String
        let confirmLabel: String
        let isDestructive: Bool
        let perform: () -> Void
    }

    func requestKill(rows targets: [ServerRowModel], title: String) {
        guard !targets.isEmpty else { return }

        pendingConfirmation = PendingConfirmation(
            message: "Kill \(targets.count) servers \(title)? This can't be undone.",
            confirmLabel: "Kill \(targets.count)",
            isDestructive: true
        ) { [weak self] in
            self?.kill(rows: targets)
        }
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        pending.perform()
    }

    func cancelPending() {
        pendingConfirmation = nil
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

        rebuildDerived()
        withAnimation(animation(Theme.Motion.kill)) {
            entries = entries
        }
    }

    private func pruneHealth(keeping ports: Set<Int>) {
        healthByPort = healthByPort.filter { ports.contains($0.key) }
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

    // MARK: - Public tunnels

    var canShare: Bool {
        TunnelService.isInstalled
    }

    func tunnel(for port: Int) -> TunnelInfo? {
        tunnels[port]
    }

    /// Asks first. A quick tunnel puts the port on the open internet with no
    /// authentication in front of it, which is not something to do by mistake.
    func requestShare(_ entry: ServerEntry) {
        guard canShare else {
            actionMessage = TunnelError.notInstalled.localizedDescription
            clearActionMessageLater()
            return
        }

        pendingConfirmation = PendingConfirmation(
            message: "Put port \(entry.port) on the public internet? Anyone with the link can reach it.",
            confirmLabel: "Share",
            isDestructive: false
        ) { [weak self] in
            self?.startTunnel(port: entry.port)
        }
    }

    func startTunnel(port: Int) {
        tunnels[port] = TunnelInfo(status: .starting)

        Task { [weak self] in
            guard let self else { return }

            do {
                let url = try await tunnelService.start(port: port)

                // Hold at .starting until DNS has the hostname. Handing over a URL
                // that isn't resolvable yet means the first click fails and macOS
                // caches that failure, which reads as a broken tunnel.
                if let host = TunnelService.hostname(from: url) {
                    _ = await TunnelService.waitUntilResolvable(host: host)
                }

                tunnels[port] = TunnelInfo(status: .active, url: url, startedAt: Date())
                copy(url)
                actionMessage = "Public URL copied to the clipboard."
                clearActionMessageLater()
            } catch {
                tunnels[port] = TunnelInfo(status: .failed, error: error.localizedDescription)
                actionMessage = error.localizedDescription
                clearActionMessageLater()
            }
        }
    }

    func stopTunnel(port: Int) {
        tunnels.removeValue(forKey: port)

        Task { [weak self] in
            await self?.tunnelService.stop(port: port)
        }
    }

    func stopAllTunnels() async {
        tunnels.removeAll()
        await tunnelService.stopAll()
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
        rebuildDerived()
        withAnimation(animation(Theme.Motion.listUpdate)) { entries = entries }
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
        rebuildDerived()
        withAnimation(animation(Theme.Motion.listUpdate)) { entries = entries }
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
