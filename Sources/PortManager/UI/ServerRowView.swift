import SwiftUI

/// One line in the list: status, port, what it is, and how it's doing.
///
/// Everything a row shows is scannable at a glance; anything that needs a second
/// look lives in the expanded card below it, never in a submenu.
struct ServerRowView: View {
    let row: ServerRowModel
    let isSelected: Bool
    let isExpanded: Bool
    let isConflicted: Bool
    let store: ServerStore

    @State private var isHovered = false
    @State private var isKilling = false

    private var entry: ServerEntry { row.entry }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                DetailCard(row: row, store: store)
                    .padding(.horizontal, Theme.Space.regular)
                    .padding(.bottom, Theme.Space.regular)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .background(rowBackground)
        .padding(.horizontal, Theme.Space.snug)
        .opacity(isKilling ? 0 : 1)
        .scaleEffect(isKilling ? 0.96 : 1, anchor: .center)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) { isHovered = hovering }
        }
        .contextMenu { RowContextMenu(row: row, store: store) }
    }

    // MARK: Header line

    private var header: some View {
        HStack(spacing: Theme.Space.regular) {
            StatusDot(entry: entry)

            // verbatim: a port is an identifier, not a quantity — plain
            // interpolation localises it into "4,321".
            Text(verbatim: String(entry.port))
                .font(Theme.Typography.port)
                .foregroundStyle(.primary)
                .frame(minWidth: 40, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                titleLine
                metaLine
            }

            Spacer(minLength: Theme.Space.tight)

            if isHovered && !isExpanded {
                quickActions
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, Theme.Space.regular)
        .padding(.vertical, Theme.Space.regular)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedRowID = row.id
            store.toggleExpanded(row.id)
        }
    }

    private var titleLine: some View {
        HStack(spacing: Theme.Space.snug) {
            Text(entry.title)
                .font(Theme.Typography.title)
                .lineLimit(1)
                .truncationMode(.middle)

            if let badge = entry.badge {
                Chip(text: badge)
            }

            if row.portCount > 1 {
                Chip(text: "+\(row.portCount - 1)")
                    .help("\(row.portCount) ports belong to this project")
            }

            if isConflicted {
                Chip(text: "conflict", tint: Theme.Colour.hung, filled: true)
            }

            if entry.state == .staleWorktree {
                Chip(text: "stale", tint: Theme.Colour.stale, filled: true)
            } else if entry.state == .orphan {
                Chip(text: "orphan", tint: Theme.Colour.orphan, filled: true)
            }
        }
    }

    /// Second line of a row.
    ///
    /// Every value that changes on a refresh — CPU, uptime — is monospaced-digit and
    /// given a reserved width. Otherwise `0.0%` becoming `12.4%` reflows the whole
    /// line every two seconds, which reads as the row twitching.
    private var metaLine: some View {
        HStack(spacing: Theme.Space.regular) {
            if store.showGitBranch, let branch = entry.git?.branch {
                MetaLabel(
                    symbol: "arrow.triangle.branch",
                    text: dirtyBranchLabel(branch, git: entry.git)
                )
                .lineLimit(1)
            }

            if store.showMetrics, let cpu = entry.metrics?.cpuPercent {
                HStack(spacing: Theme.Space.tight) {
                    Text(verbatim: Format.cpu(cpu))
                        .font(Theme.Typography.meta)
                        .monospacedDigit()
                        .foregroundStyle(cpu > 80 ? Theme.Colour.hung : Color.secondary)
                        .frame(width: 38, alignment: .leading)

                    if store.showSparklines {
                        // Always occupies its slot, even before there's enough history
                        // to draw, so the line doesn't jump when the trace appears.
                        Sparkline(
                            values: store.cpuTrace(for: row.id),
                            tint: cpu > 80 ? Theme.Colour.hung : .secondary
                        )
                    }
                }
            }

            if store.showMetrics, let uptime = entry.metrics?.uptime {
                Text(verbatim: Format.uptime(uptime))
                    .font(Theme.Typography.meta)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 46, alignment: .leading)
            }

            if store.showPageTitles, let title = entry.health?.pageTitle, entry.git?.branch == nil {
                Text("“\(title)”")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if entry.health?.state == .hung {
                MetaLabel(symbol: "exclamationmark.triangle.fill", text: "not responding", tint: Theme.Colour.hung)
            }

            if entry.exposure == .network {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(Exposure.network.label)
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func dirtyBranchLabel(_ branch: String, git: GitStatus?) -> String {
        guard let count = git?.dirtyCount, count > 0 else { return branch }
        return "\(branch) •\(count)"
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 1) {
            if entry.health?.state != .nonHTTP {
                IconButton(symbol: "arrow.up.right.square", help: "Open in browser") {
                    store.open(entry)
                }
            }

            IconButton(symbol: "doc.on.doc", help: "Copy URL") {
                store.copy(store.url(for: entry).absoluteString)
            }

            IconButton(symbol: "xmark.circle", help: killHelp, destructive: true) {
                killWithAnimation()
            }
        }
    }

    private var killHelp: String {
        entry.container == nil ? "Kill process" : "Stop container"
    }

    private func killWithAnimation() {
        withAnimation(store.animation(Theme.Motion.kill)) { isKilling = true }

        Task {
            try? await Task.sleep(for: .milliseconds(180))
            store.kill(row)
        }
    }

    // MARK: Background

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row)
            .fill(fill)
    }

    private var fill: Color {
        if isExpanded { return Theme.Colour.cardFill }
        if isSelected { return Theme.Colour.rowSelected }
        if isHovered { return Theme.Colour.rowHover }
        return .clear
    }
}

// MARK: - Context menu

struct RowContextMenu: View {
    let row: ServerRowModel
    let store: ServerStore

    private var entry: ServerEntry { row.entry }

    var body: some View {
        Button("Open in Browser") { store.open(entry) }
        Button("Copy Local URL") { store.copy(store.url(for: entry).absoluteString) }

        if let network = store.networkURL(for: entry) {
            Button("Copy Network URL") { store.copy(network) }
        }

        Button("Copy Port") { store.copy("\(entry.port)") }

        Divider()

        if let path = entry.path {
            Button("Copy Project Path") { store.copy(path) }
            Button("Reveal in Finder") { AppLauncher.revealInFinder(path: path) }
            Button("Open in Editor") {
                AppLauncher.openInEditor(path: path, bundleID: Preferences.editorBundleID)
            }
            Button("Open in Terminal") {
                AppLauncher.openTerminal(path: path, bundleID: Preferences.terminalBundleID)
            }
        }

        Divider()

        Button(store.isPinned(entry) ? "Unpin \(entry.pinNoun)" : "Pin \(entry.pinNoun)") {
            store.togglePin(entry)
        }
        Button("Ignore Port " + String(entry.port)) { store.ignorePort(entry) }
        Button("Ignore \(entry.pinNoun)") { store.ignoreTarget(entry) }

        Divider()

        Button(entry.container == nil ? "Kill Process" : "Stop Container", role: .destructive) {
            store.kill(row)
        }
    }
}
