import AppKit
import SwiftUI

/// The expanded half of a row.
///
/// Everything that used to require walking two or three levels of submenu is on
/// this one card: the path, the metrics, the sibling ports, and every action.
struct DetailCard: View {
    let row: ServerRowModel
    let store: ServerStore

    @State private var preview: NSImage?
    @State private var isLoadingPreview = false

    private var entry: ServerEntry { row.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.comfy) {
            if shouldShowPreview {
                previewSection
            }

            if let path = entry.displayPath {
                pathRow(path)
            }

            statStrip

            if let health = entry.health, health.state != .unknown {
                healthRow(health)
            }

            exposureRow

            if let container = entry.container {
                dockerRow(container)
            }

            if !row.related.isEmpty {
                relatedPorts
            }

            if entry.state != .active {
                stateNote
            }

            actions
        }
        .padding(Theme.Space.comfy)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colour.chipFill.opacity(0.6))
        )
        .task(id: entry.id) {
            await loadPreview()
        }
    }

    // MARK: Preview

    private var shouldShowPreview: Bool {
        Preferences.previewsEnabled && entry.health?.state == .healthy
    }

    private var previewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                .fill(Color.primary.opacity(0.05))

            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
            } else if isLoadingPreview {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(height: Theme.Size.thumbnailHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
        .overlay(alignment: .topTrailing) {
            if preview != nil {
                IconButton(symbol: "arrow.clockwise", help: "Refresh preview") {
                    Task { await loadPreview(force: true) }
                }
                .padding(Theme.Space.tight)
            }
        }
        .onTapGesture { store.open(entry) }
    }

    private func loadPreview(force: Bool = false) async {
        guard shouldShowPreview else { return }

        if !force, let cached = PreviewSnapshotter.shared.cachedSnapshot(port: entry.port) {
            preview = cached
            return
        }

        isLoadingPreview = true
        defer { isLoadingPreview = false }
        preview = await PreviewSnapshotter.shared.snapshot(port: entry.port, force: force)
    }

    // MARK: Rows

    private func pathRow(_ path: String) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Text(path)
                .font(Theme.Typography.metaMono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)

            Spacer(minLength: 0)

            if let full = entry.path {
                IconButton(symbol: "doc.on.doc", help: "Copy path") { store.copy(full) }
                IconButton(symbol: "folder", help: "Reveal in Finder") {
                    AppLauncher.revealInFinder(path: full)
                }
            }
        }
    }

    private var statStrip: some View {
        HStack(alignment: .top, spacing: Theme.Space.loose) {
            Stat(label: "CPU", value: entry.metrics?.cpuPercent.map(Format.cpu))
            Stat(label: "Memory", value: entry.metrics?.residentBytes.map(Format.memory))
            Stat(label: "Uptime", value: entry.metrics?.uptime.map(Format.uptime))
            Stat(label: "Energy", value: entry.metrics?.energyLevel?.label)
            Stat(label: "PID", value: entry.primaryPID.map { "\($0)" })
            Spacer(minLength: 0)
        }
    }

    private func healthRow(_ health: HealthReport) -> some View {
        HStack(spacing: Theme.Space.snug) {
            switch health.state {
            case .healthy:
                MetaLabel(
                    symbol: "checkmark.circle.fill",
                    text: healthSummary(health),
                    tint: Theme.Colour.healthy
                )
            case .hung:
                MetaLabel(
                    symbol: "exclamationmark.triangle.fill",
                    text: "Holding the port but not answering",
                    tint: Theme.Colour.hung
                )
            case .nonHTTP:
                MetaLabel(symbol: "terminal", text: "Not an HTTP server")
            case .refused:
                MetaLabel(symbol: "xmark.circle", text: "Connection refused")
            case .probing, .unknown:
                EmptyView()
            }

            Spacer(minLength: 0)
        }
    }

    private func healthSummary(_ health: HealthReport) -> String {
        var parts: [String] = []
        if let code = health.statusCode { parts.append("\(code)") }
        if let latency = health.latency { parts.append(Format.latency(latency)) }
        if let title = health.pageTitle { parts.append("“\(title)”") }
        return parts.isEmpty ? "Responding" : parts.joined(separator: " · ")
    }

    /// Says plainly whether anyone else can reach this. The bind address is in every
    /// `lsof` scan already and nothing else in this category surfaces it.
    private var exposureRow: some View {
        HStack(spacing: Theme.Space.snug) {
            if entry.exposure == .network, let network = store.networkURL(for: entry) {
                MetaLabel(symbol: "antenna.radiowaves.left.and.right", text: network)

                IconButton(symbol: "doc.on.doc", help: "Copy network URL") {
                    store.copy(network)
                }
            } else {
                MetaLabel(symbol: "lock", text: Exposure.loopback.label)
            }

            Spacer(minLength: 0)
        }
    }

    private func dockerRow(_ container: DockerContainer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            MetaLabel(symbol: "shippingbox", text: container.name)
            MetaLabel(symbol: "square.stack.3d.up", text: container.image)

            if container.containerPort != nil {
                MetaLabel(symbol: "arrow.left.arrow.right", text: container.portMappingLabel)
            }
        }
    }

    private var relatedPorts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Other ports")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.tertiary)

            ForEach(row.related) { related in
                HStack(spacing: Theme.Space.snug) {
                    Text(verbatim: String(related.port))
                        .font(Theme.Typography.metaMono)
                        .foregroundStyle(.secondary)

                    Text(related.isLikelyHelperPort ? "helper" : related.prettyCommand)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)

                    IconButton(symbol: "arrow.up.right.square", help: "Open") {
                        store.open(related)
                    }
                }
            }
        }
    }

    private var stateNote: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colour.stale)

            Text(stateMessage)
                .font(Theme.Typography.meta)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var stateMessage: String {
        switch entry.state {
        case .staleWorktree:
            return "Agent worktree is gone — this server is running against deleted files"
        case .orphan:
            return "Project folder no longer exists"
        case .active:
            return ""
        }
    }

    // MARK: Actions

    private var actions: some View {
        FlowRow(spacing: Theme.Space.snug) {
            if entry.health?.state != .nonHTTP {
                ActionButton(label: "Open", symbol: "arrow.up.right.square", prominent: true) {
                    store.open(entry)
                }
            }

            ActionButton(label: "Copy URL", symbol: "doc.on.doc") {
                store.copy(store.url(for: entry).absoluteString)
            }

            if let network = store.networkURL(for: entry) {
                ActionButton(label: "Network URL", symbol: "wifi") {
                    store.copy(network)
                }
            }

            if let path = entry.path {
                ActionButton(label: "Terminal", symbol: "terminal") {
                    Task { await openTerminal(path: path) }
                }

                ActionButton(label: "Editor", symbol: "chevron.left.forwardslash.chevron.right") {
                    AppLauncher.openInEditor(path: path, bundleID: Preferences.editorBundleID)
                }
            }

            if store.canRestart(row) {
                ActionButton(label: "Restart", symbol: "arrow.clockwise") {
                    store.restart(row)
                }
            }

            ActionButton(
                label: store.isPinned(entry) ? "Unpin" : "Pin",
                symbol: store.isPinned(entry) ? "pin.slash" : "pin"
            ) {
                store.togglePin(entry)
            }

            ActionButton(
                label: entry.container == nil ? "Kill" : "Stop",
                symbol: "xmark",
                destructive: true
            ) {
                store.kill(row)
            }
        }
    }

    /// Tries to focus the terminal tab this server actually runs in; falls back to
    /// a fresh terminal at the project root, which is the common case here since
    /// long-lived dev servers usually outlive their shell.
    private func openTerminal(path: String) async {
        if let pid = entry.primaryPID, await TerminalAttach.focusTerminal(forPID: pid) {
            return
        }

        AppLauncher.openTerminal(path: path, bundleID: Preferences.terminalBundleID)
    }
}

// MARK: - Stat

private struct Stat: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.3)

            Text(value ?? Format.unavailable)
                .font(Theme.Typography.metaMono)
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
    }
}

// MARK: - Flow layout

/// Wraps action buttons onto as many lines as they need. The action set varies by
/// row — a Docker container has no Restart, a database has no Open — so a fixed
/// grid would leave holes.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY

        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }

            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.width == 0 ? size.width : current.width + spacing + size.width

            if projected > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }

            current.indices.append(index)
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
