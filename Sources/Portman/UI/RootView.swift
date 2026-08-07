import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var store: ServerStore
    let dismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var collapsedSections: Set<String> = []
    /// Sections we've already auto-folded once, so a manual expand isn't undone
    /// on the next scan.
    @State private var autoCollapsed: Set<String> = []

    init(store: ServerStore, dismiss: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: Theme.Panel.width, alignment: .top)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius)
                .strokeBorder(Theme.Colour.separator, lineWidth: 0.5)
        )
        .onAppear {
            searchFocused = true
            applyDefaultCollapse()
        }
        .onChange(of: store.sections.map(\.id)) { _, _ in
            applyDefaultCollapse()
        }
    }

    private func applyDefaultCollapse() {
        for section in store.sections where section.startsCollapsed && !autoCollapsed.contains(section.id) {
            autoCollapsed.insert(section.id)
            collapsedSections.insert(section.id)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Space.regular) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                TextField("Search ports, projects, frameworks…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { openSelected() }

                if !store.searchText.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", help: "Clear") {
                        store.searchText = ""
                    }
                }

                if !store.rows.isEmpty {
                    IconButton(
                        symbol: store.isSelectingServers ? "xmark" : "checklist",
                        help: store.isSelectingServers ? "Cancel selection" : "Select servers"
                    ) {
                        withAnimation(store.animation(Theme.Motion.listUpdate)) {
                            if store.isSelectingServers {
                                store.endServerSelection()
                            } else {
                                store.beginServerSelection()
                            }
                        }
                    }
                }

                optionsMenu
            }

            filterRow
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, Theme.Space.comfy)
        .padding(.bottom, Theme.Space.regular)
    }

    private var filterRow: some View {
        HStack(spacing: Theme.Space.tight) {
            ForEach(EntryFilter.allCases, id: \.self) { filter in
                FilterChip(
                    label: filter.label,
                    isActive: store.filter == filter,
                    count: store.count(for: filter)
                ) {
                    withAnimation(store.animation(Theme.Motion.listUpdate)) {
                        store.filter = store.filter == filter && filter != .all ? .all : filter
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Sort by", selection: $store.sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }

            Picker("Group", selection: $store.groupMode) {
                ForEach(GroupMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Picker("Rows", selection: $store.rowDensity) {
                ForEach(RowDensity.allCases, id: \.self) { density in
                    Text(density.label).tag(density)
                }
            }

            Divider()

            Toggle("Show system ports", isOn: $store.showAllProcesses)

            Button("Refresh") { store.refresh(force: true) }
                .keyboardShortcut("r")

            Divider()

            if UpdateController.shared.isConfigured {
                // Names the version when one is waiting: the menu is where people go
                // looking for updates, so it shouldn't ask you to check for something it
                // already knows about.
                Button(
                    UpdateController.shared.pendingUpdate.map { "Update to \($0)…" }
                        ?? "Check for Updates…"
                ) {
                    // Same reason as the footer button: whatever Sparkle puts on screen
                    // would open behind the panel, and it doesn't always tell us.
                    dismiss()
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!UpdateController.shared.canCheckForUpdates)
            }

            Button("Settings…") {
                // The panel outranks every ordinary window, so it has to go first.
                dismiss()
                SettingsWindow.shared.show(store: store)
            }
            .keyboardShortcut(",")

            Button("Quit \(AppInfo.displayName)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                // Eager, not lazy. A few dozen rows cost nothing to lay out, and
                // LazyVStack recycling rows during a refresh moves the scroll
                // position under the pointer.
                VStack(spacing: 0) {
                    ForEach(store.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, Theme.Space.snug)
                .background(alignment: .topLeading) {
                    SmallVerticalScroller()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .scrollIndicators(.automatic)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ServerSection) -> some View {
        if let title = section.title {
            SectionHeader(
                title: title,
                count: section.rows.count,
                isCollapsed: section.isCollapsible ? collapsedSections.contains(section.id) : nil,
                toggle: section.isCollapsible ? { toggleSection(section.id) } : nil,
                killAll: section.startsCollapsed && !store.isSelectingServers
                    ? { store.requestKill(rows: section.rows, title: title.lowercased()) }
                    : nil
            )
        }

        if !collapsedSections.contains(section.id) {
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                ServerRowView(
                    row: row,
                    isSelected: store.selectedRowID == row.id,
                    isSelecting: store.isSelectingServers,
                    isChecked: store.selectedServerIDs.contains(row.id),
                    isExpanded: store.expandedRowID == row.id,
                    isConflicted: store.conflictPorts.contains(row.entry.port),
                    // Rows inside an Orphans or Stale section don't repeat what the
                    // section header already says.
                    showsStateChip: section.style == .main || section.style == .pinned,
                    showsTopDivider: index > 0,
                    store: store
                )
            }
        }
    }

    private func toggleSection(_ id: String) {
        withAnimation(store.animation(Theme.Motion.expand)) {
            if collapsedSections.contains(id) {
                collapsedSections.remove(id)
            } else {
                collapsedSections.insert(id)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.snug) {
            Image(systemName: emptyStateSymbol)
                .font(.system(size: 22))
                .foregroundStyle(.quaternary)

            Text(emptyStateTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if let hint = emptyStateHint {
                Text(hint)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        // Fills the list area so the footer stays pinned to the bottom of the panel
        // instead of floating halfway up it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.loose)
    }

    private var emptyStateSymbol: String {
        if store.isScanning && store.entries.isEmpty { return "circle.dotted" }
        return store.isFiltering ? "line.3.horizontal.decrease.circle" : "moon.zzz"
    }

    private var emptyStateTitle: String {
        if store.isScanning && store.entries.isEmpty { return "Scanning…" }
        return store.isFiltering ? "Nothing matches" : "No servers listening"
    }

    private var emptyStateHint: String? {
        if store.isScanning && store.entries.isEmpty { return nil }

        if store.isFiltering {
            return "Try a different search, or clear the filter."
        }

        return "Start a dev server and it'll show up here."
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let pending = store.pendingConfirmation {
            confirmBar(pending)
        } else {
            normalFooter
        }
    }

    /// Confirmation lives inside the panel rather than in a `confirmationDialog`.
    ///
    /// A dialog is its own window, so presenting it took key away from the panel —
    /// which dismissed the panel out from under the dialog, and resized it off its
    /// menu bar anchor on the way back.
    private func confirmBar(_ pending: ServerStore.PendingConfirmation) -> some View {
        HStack(spacing: Theme.Space.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(pending.isDestructive ? Theme.Colour.destructive : Theme.Colour.hung)

            Text(pending.message)
                .font(Theme.Typography.meta)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            ActionButton(label: "Cancel") { store.cancelPending() }

            ActionButton(
                label: pending.confirmLabel,
                destructive: pending.isDestructive,
                prominent: !pending.isDestructive
            ) {
                store.confirmPending()
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.regular)
        .background(
            (pending.isDestructive ? Theme.Colour.destructive : Theme.Colour.hung).opacity(0.08)
        )
    }

    private var normalFooter: some View {
        HStack(spacing: Theme.Space.regular) {
            Text(summary)
                .font(Theme.Typography.meta)
                .foregroundStyle(store.actionMessage == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.Colour.hung))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if store.isSelectingServers {
                if !store.selectedServers.isEmpty {
                    ActionButton(
                        label: "Kill \(store.selectedServers.count)",
                        symbol: "xmark",
                        destructive: true
                    ) {
                        store.requestKillSelectedServers()
                    }
                }
            } else if store.isFiltering && !store.rows.isEmpty {
                ActionButton(
                    label: "Kill all \(store.rows.count)",
                    symbol: "xmark",
                    destructive: true
                ) {
                    store.requestKill(rows: store.rows, title: "matching this filter")
                }
            } else if let version = UpdateController.shared.pendingUpdate {
                // Sparkle found this on a check nobody asked for, and we told it not to
                // put a dialog up for that. This is the reminder instead: it waits here
                // until you're looking, and clicking it hands over to Sparkle's own alert.
                // Yielding to "Kill all" isn't a compromise — a footer with two buttons in
                // 400 points stops being a glance, and an update can wait for the filter
                // to clear.
                ActionButton(label: "Update to \(version)", symbol: "arrow.down.circle") {
                    // Dismiss first, like the Settings button, and don't rely on the
                    // delegate to do it: Sparkle only announces an alert it's about to show
                    // when the check was user-initiated, and this update came from a
                    // scheduled one. Clicking here only brings that existing alert into
                    // focus, which it says nothing about — so the panel would sit on top
                    // of the very window it just asked for.
                    dismiss()
                    UpdateController.shared.checkForUpdates()
                }
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.regular)
    }

    private var summary: String {
        if let message = store.actionMessage { return message }
        if store.isScanning && store.entries.isEmpty { return "Scanning…" }

        if store.isSelectingServers {
            let count = store.selectedServers.count
            if count == 0 { return "Select servers to kill" }
            return count == 1 ? "1 server selected" : "\(count) servers selected"
        }

        let count = store.rows.count
        let noun = count == 1 ? "server" : "servers"

        if store.isFiltering {
            return "\(count) \(noun) matching"
        }

        return "\(count) \(noun) listening"
    }

    // MARK: - Keyboard

    private func openSelected() {
        guard let row = store.selectedRow ?? store.rows.first else { return }

        if store.isSelectingServers {
            store.toggleServerSelection(row.id)
            return
        }

        store.open(row.entry)
        dismiss()
    }
}

/// SwiftUI exposes whether a scroll indicator is visible, but not its size.
/// Respect the system's visibility setting while using AppKit's narrower control
/// size, since a full-width legacy scroller takes too much from this small panel.
private struct SmallVerticalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.configure()
    }

    final class ConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            var ancestor = superview

            while let view = ancestor {
                if let scrollView = view as? NSScrollView {
                    scrollView.verticalScroller?.controlSize = .small
                    return
                }

                ancestor = view.superview
            }
        }
    }
}
