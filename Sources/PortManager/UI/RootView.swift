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
        .frame(width: Theme.Panel.width)
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
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { store.pendingKill != nil },
                set: { if !$0 { store.cancelPendingKill() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Kill \(store.pendingKill?.rows.count ?? 0) servers", role: .destructive) {
                store.confirmPendingKill()
            }
            Button("Cancel", role: .cancel) { store.cancelPendingKill() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var confirmationTitle: String {
        guard let pending = store.pendingKill else { return "" }
        return "Kill \(pending.rows.count) servers \(pending.title)?"
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
                    count: count(for: filter)
                ) {
                    withAnimation(Theme.Motion.listUpdate) {
                        store.filter = store.filter == filter && filter != .all ? .all : filter
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func count(for filter: EntryFilter) -> Int? {
        guard filter != .all else { return nil }

        let matching = store.entries
            .filter { !store.isIgnored($0) }
            .filter { store.showAllProcesses || !$0.hiddenByDefault }
            .filter { filter.matches($0) }
            .count

        return matching > 0 ? matching : nil
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

            Divider()

            Toggle("Show system ports", isOn: $store.showAllProcesses)

            Button("Refresh") { store.refresh(force: true) }
                .keyboardShortcut("r")

            Divider()

            Button("Settings…") { SettingsWindow.shared.show(store: store) }
                .keyboardShortcut(",")

            Button("Quit Port Manager") { NSApplication.shared.terminate(nil) }
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
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(store.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, Theme.Space.snug)
            }
            .frame(maxHeight: Theme.Panel.maxHeight)
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
                killAll: section.startsCollapsed
                    ? { store.requestKill(rows: section.rows, title: title.lowercased()) }
                    : nil
            )
        }

        if !collapsedSections.contains(section.id) {
            ForEach(section.rows) { row in
                ServerRowView(
                    row: row,
                    isSelected: store.selectedRowID == row.id,
                    isExpanded: store.expandedRowID == row.id,
                    isConflicted: store.conflictPorts.contains(row.entry.port),
                    store: store
                )
            }
        }
    }

    private func toggleSection(_ id: String) {
        withAnimation(Theme.Motion.expand) {
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
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

    private var footer: some View {
        HStack(spacing: Theme.Space.regular) {
            Text(summary)
                .font(Theme.Typography.meta)
                .foregroundStyle(store.actionMessage == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.Colour.hung))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if store.isFiltering && !store.rows.isEmpty {
                ActionButton(
                    label: "Kill all \(store.rows.count)",
                    symbol: "xmark",
                    destructive: true
                ) {
                    store.requestKill(rows: store.rows, title: "matching this filter")
                }
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.regular)
    }

    private var summary: String {
        if let message = store.actionMessage { return message }
        if store.isScanning && store.entries.isEmpty { return "Scanning…" }

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
        store.open(row.entry)
        dismiss()
    }
}
