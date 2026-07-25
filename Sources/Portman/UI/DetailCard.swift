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

            if let tunnel = store.tunnel(for: entry.port) {
                tunnelRow(tunnel)
            }

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
            // Expanding a row is the one moment worth re-checking: the reading in
            // the card should be current, not whatever was true when the server
            // first appeared in the list.
            store.recheckHealth(for: entry)
            await loadPreview()
        }
    }

    // MARK: Preview

    /// Decided from the kind of server, not from the health result.
    ///
    /// Gating on `health == .healthy` meant the preview slot appeared a second after
    /// the card opened, shoving everything below it down. Reserving the space up front
    /// for anything that could serve HTTP keeps the card still.
    private var shouldShowPreview: Bool {
        guard store.previewsEnabled else { return false }
        guard entry.kind != .database, entry.kind != .system else { return false }
        return entry.health?.state != .nonHTTP
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
                    // Cross-fades in place instead of snapping, and the slot is already
                    // reserved, so nothing below it moves.
                    .transition(.opacity)
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

        let image = await PreviewSnapshotter.shared.snapshot(port: entry.port, force: force)

        // Keep the old thumbnail on a failed refresh rather than blanking the slot.
        guard let image else { return }

        withAnimation(store.animation(.easeOut(duration: 0.2))) {
            preview = image
        }
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
        HStack(alignment: .top, spacing: Theme.Space.regular) {
            Stat(label: "CPU", value: entry.metrics?.cpuPercent.map(Format.cpu), width: 52)
            Stat(label: "Memory", value: entry.metrics?.residentBytes.map(Format.memory), width: 66)
            Stat(label: "Uptime", value: entry.metrics?.uptime.map(Format.uptime), width: 66)
            Stat(label: "Energy", value: entry.metrics?.energyLevel?.label, width: 52)
            Stat(label: "PID", value: entry.primaryPID.map { String($0) }, width: 56)
            Spacer(minLength: 0)
        }
    }

    /// The page title gets its own line.
    ///
    /// It used to follow the latency on one line, so every probe — where `42ms`
    /// becomes `70ms` — shifted the title sideways and could change where it wrapped,
    /// moving a whole line of text. Nothing downstream of a changing number now.
    private func healthRow(_ health: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            statusLine(health)

            if health.state == .healthy, let title = health.pageTitle {
                Text("“\(title)”")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusLine(_ health: HealthReport) -> some View {
        HStack(spacing: Theme.Space.snug) {
            switch health.state {
            case .healthy:
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colour.healthy)

                    if let code = health.statusCode {
                        Text(verbatim: String(code))
                            .monospacedDigit()
                    }

                    if let latency = health.latency {
                        Text(verbatim: Format.latency(latency))
                            .monospacedDigit()
                            // Fixed slot: latency moves on every probe and must not
                            // push anything along with it.
                            .frame(width: 46, alignment: .leading)
                    }
                }
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colour.healthy)

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

    /// The public URL, once a quick tunnel is up.
    @ViewBuilder
    private func tunnelRow(_ tunnel: TunnelInfo) -> some View {
        HStack(spacing: Theme.Space.snug) {
            switch tunnel.status {
            case .starting:
                ProgressView().controlSize(.small)
                MetaLabel(symbol: nil, text: "Opening a public tunnel…")

            case .active:
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colour.hung)

                Text(tunnel.url ?? "")
                    .font(Theme.Typography.metaMono)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Anyone with this link can reach port \(entry.port)")

                if let url = tunnel.url {
                    IconButton(symbol: "doc.on.doc", help: "Copy public URL") {
                        store.copy(url)
                    }

                    IconButton(symbol: "arrow.up.right.square", help: "Open public URL") {
                        if let link = URL(string: url) {
                            AppLauncher.openInBrowser(link, bundleID: Preferences.browserBundleID)
                        }
                    }
                }

            case .failed:
                MetaLabel(
                    symbol: "exclamationmark.triangle.fill",
                    text: tunnel.error ?? "Tunnel failed",
                    tint: Theme.Colour.hung
                )
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

            if store.tunnel(for: entry.port) != nil {
                ActionButton(label: "Stop sharing", symbol: "globe.slash") {
                    store.stopTunnel(port: entry.port)
                }
            } else if entry.health?.state != .nonHTTP {
                // Shown even without cloudflared installed — tapping it explains what's
                // missing, which beats the feature simply not existing.
                ActionButton(label: "Share", symbol: "globe") {
                    store.requestShare(entry)
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

/// One labelled figure in the stat strip.
///
/// Fixed width on purpose: these values change on every refresh and at different
/// widths (`447 MB` → `1.2 GB`, `18h 14m` → `1d 3h`). In a plain HStack each one
/// would shove the rest of the strip sideways.
private struct Stat: View {
    let label: String
    let value: String?
    var width: CGFloat = 66

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.3)

            Text(value ?? Format.unavailable)
                .font(Theme.Typography.metaMono)
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
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
