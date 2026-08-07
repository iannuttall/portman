import SwiftUI

/// One line in the list: status, port, what it is, and how it's doing.
///
/// Everything a row shows is scannable at a glance; anything that needs a second
/// look lives in the expanded card below it, never in a submenu.
struct ServerRowView: View {
    let row: ServerRowModel
    let isSelected: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let isExpanded: Bool
    let isConflicted: Bool
    let showsStateChip: Bool
    let showsTopDivider: Bool
    let store: ServerStore

    @State private var isHovered = false
    @State private var isKilling = false

    private var entry: ServerEntry { row.entry }

    var body: some View {
        VStack(spacing: 0) {
            if showsTopDivider && !isExpanded {
                Divider()
                    .opacity(0.4)
                    .padding(.horizontal, Theme.Space.comfy)
            }

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
        HStack(spacing: Theme.Space.comfy) {
            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        isChecked || isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.tertiary)
                    )
                    // Replaces the status dot in selection mode and keeps its slot,
                    // so every title stays on the same left edge as the normal row.
                    .frame(width: Theme.Size.statusDot)
                    .transition(.opacity.combined(with: .scale))
            } else {
                StatusDot(entry: entry)
            }

            VStack(alignment: .leading, spacing: 2) {
                nameLine

                if let meta = metaText {
                    Text(meta)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(metaHelp)
                }
            }

            Spacer(minLength: Theme.Space.tight)

            if isHovered && !isExpanded && !isSelecting {
                quickActions
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.comfy)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                store.toggleServerSelection(row.id)
            } else {
                store.selectedRowID = row.id
                store.toggleExpanded(row.id)
            }
        }
    }

    private var nameLine: some View {
        HStack(spacing: Theme.Space.snug) {
            projectTitle
                .font(Theme.Typography.title)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(verbatim: ":" + String(entry.port))
                .font(Theme.Typography.port)
                .foregroundStyle(Theme.Colour.port)

            // Only what genuinely needs attention earns a chip. Framework and port
            // count moved to the quiet line below; orphan and stale are already
            // stated by the section they sit in.
            // Hidden inside a "Conflict on :3000" section, which already says it.
            if isConflicted, showsStateChip {
                Chip(
                    text: "conflict",
                    tint: Theme.Colour.hung,
                    help: "Another process is listening on port \(entry.port) too"
                )
            }

            if showsStateChip, entry.state == .staleWorktree {
                Chip(
                    text: "stale",
                    tint: Theme.Colour.stale,
                    help: "The agent worktree this came from has been deleted — safe to kill"
                )
            } else if showsStateChip, entry.state == .orphan {
                Chip(
                    text: "orphan",
                    tint: Theme.Colour.orphan,
                    help: "This server's project folder no longer exists — safe to kill"
                )
            }

            if store.tunnel(for: entry.port)?.status == .active {
                Chip(
                    text: "public",
                    tint: Theme.Colour.hung,
                    help: "Shared on the public internet through a Cloudflare tunnel"
                )
            }

            if entry.health?.state == .hung {
                Chip(
                    text: "not responding",
                    tint: Theme.Colour.hung,
                    help: "Holding the port but not answering requests"
                )
            }
        }
    }

    private var projectTitle: Text {
        guard let qualifier = row.projectQualifier else {
            return Text(entry.title).foregroundStyle(.primary)
        }

        return Text(qualifier + " / ")
            .foregroundStyle(.secondary)
            + Text(entry.title).foregroundStyle(.primary)
    }

    /// The quiet second line, composed as one string.
    ///
    /// Deliberately a single `Text` rather than a row of separately framed values:
    /// nothing can push anything else around as figures change, and it reads as a
    /// sentence instead of a dashboard.
    private var metaText: String? {
        var parts: [String] = []

        if store.showGitBranch, let branch = entry.git?.branch {
            parts.append(dirtyBranchLabel(branch, git: entry.git))
        }

        if let framework = entry.badge {
            parts.append(framework)
        }

        if row.portCount > 1 {
            parts.append("+\(row.portCount - 1) ports")
        }

        if store.rowDensity == .detailed, store.showMetrics {
            if let cpu = entry.metrics?.cpuPercent {
                parts.append(Format.cpu(cpu))
            }
        }

        if let uptime = entry.metrics?.uptime {
            parts.append(Format.uptime(uptime))
        }

        if store.rowDensity == .detailed, store.showPageTitles,
           let title = entry.health?.pageTitle {
            parts.append("“\(title)”")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func dirtyBranchLabel(_ branch: String, git: GitStatus?) -> String {
        guard let count = git?.dirtyCount, count > 0 else { return branch }
        // A thin space, not a full one: the marker belongs to the count, so the
        // two read as a single token rather than another ` · ` separated part.
        // Set solid, U+2022 collides with the digit — it's a heavier glyph than
        // the U+00B7 separators and needs the gap more, not less.
        return "\(branch) •\u{2009}\(count)"
    }

    private func branchHelp(git: GitStatus?) -> String {
        guard let count = git?.dirtyCount, count > 0 else { return "Git branch" }
        return "Git branch — \(count) uncommitted change\(count == 1 ? "" : "s")"
    }

    private var metaHelp: String {
        var lines: [String] = []
        if let branch = entry.git?.branch { lines.append("Branch \(branch)") }
        if let framework = entry.badge { lines.append(framework) }
        if let uptime = entry.metrics?.uptime { lines.append("Up \(Format.uptime(uptime))") }
        if entry.exposure == .network { lines.append(Exposure.network.label) }
        return lines.joined(separator: " · ")
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: Theme.Space.tight) {
            ActionButton(label: entry.container == nil ? "Kill" : "Stop", destructive: true) {
                killWithAnimation()
            }

            if entry.health?.state != .nonHTTP {
                ActionButton(label: "Open") { store.open(entry) }
            }
        }
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
            // Selected rows are separate choices, not one card. Give consecutive
            // highlights enough air that their rounded corners never touch.
            .padding(.vertical, isSelecting ? Theme.Space.hairline : 0)
    }

    private var fill: Color {
        if isExpanded { return Theme.Colour.cardFill }
        if isChecked { return Theme.Colour.rowSelected }
        if isSelected && !isSelecting { return Theme.Colour.rowSelected }
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
