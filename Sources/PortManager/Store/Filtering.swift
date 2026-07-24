import Foundation

/// One list row: a primary listener plus any sibling ports belonging to the same
/// project or container.
///
/// A Vite project typically holds three or four ports; showing all of them as
/// peers is what made the old menu unreadable. The primary port gets the row and
/// the rest are folded into its expanded card.
struct ServerRowModel: Identifiable, Hashable, Sendable {
    let entry: ServerEntry
    let related: [ServerEntry]

    var id: String { entry.id }

    var allPIDs: [Int32] {
        Array(Set(([entry] + related).flatMap(\.pids))).sorted()
    }

    var portCount: Int { related.count + 1 }
}

struct ServerSection: Identifiable, Hashable, Sendable {
    enum Style: String, Sendable, Hashable {
        case pinned
        case stale
        case orphan
        case main
        case project
        case kind
    }

    let id: String
    let title: String?
    let style: Style
    let rows: [ServerRowModel]

    var isCollapsible: Bool {
        style == .stale || style == .orphan || style == .project
    }

    /// Dead and abandoned servers are worth listing but not worth reading every
    /// time the panel opens, so they start folded away.
    var startsCollapsed: Bool {
        style == .stale || style == .orphan
    }
}

/// Pure list-shaping: search, sort, fold, group. No I/O, no state — every
/// decision the list makes is reproducible from its inputs.
enum ListShaper {
    // MARK: - Search

    /// `/pattern/` runs a regular expression; anything else is token matching
    /// where every token must appear somewhere in the entry.
    static func matches(_ entry: ServerEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }

        let haystack = searchHaystack(for: entry)

        if let pattern = regexPattern(in: trimmed) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }

            let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            return regex.firstMatch(in: haystack, range: range) != nil
        }

        let tokens = trimmed.lowercased().split(separator: " ").map(String.init)
        return tokens.allSatisfy { haystack.contains($0) }
    }

    /// Returns the inner pattern of a `/…/` query, or nil when it isn't one.
    static func regexPattern(in query: String) -> String? {
        guard query.count >= 2, query.hasPrefix("/"), query.hasSuffix("/") else { return nil }
        let pattern = String(query.dropFirst().dropLast())
        return pattern.isEmpty ? nil : pattern
    }

    static func searchHaystack(for entry: ServerEntry) -> String {
        var parts: [String] = [
            "\(entry.port)",
            entry.title,
            entry.command,
            entry.kind.rawValue
        ]

        // So "lan" or "exposed" finds everything reachable off this machine.
        if entry.exposure == .network { parts.append("lan network exposed") }

        if let subtitle = entry.subtitle { parts.append(subtitle) }
        if let path = entry.displayPath { parts.append(path) }
        if let title = entry.health?.pageTitle { parts.append(title) }
        if let branch = entry.git?.branch { parts.append(branch) }
        if let image = entry.container?.image { parts.append(image) }

        return parts.joined(separator: " ").lowercased()
    }

    // MARK: - Sort

    static func sorted(_ entries: [ServerEntry], by order: SortOrder) -> [ServerEntry] {
        switch order {
        case .port:
            return entries.sorted(by: PortScanner.byPortThenPID)
        case .name:
            return entries.sorted {
                let left = $0.title.localizedCaseInsensitiveCompare($1.title)
                return left == .orderedSame ? $0.port < $1.port : left == .orderedAscending
            }
        case .cpu:
            return entries.sorted { descending($0.metrics?.cpuPercent, $1.metrics?.cpuPercent, $0, $1) }
        case .memory:
            return entries.sorted {
                descending(
                    $0.metrics?.residentBytes.map(Double.init),
                    $1.metrics?.residentBytes.map(Double.init),
                    $0,
                    $1
                )
            }
        case .uptime:
            return entries.sorted { descending($0.metrics?.uptime, $1.metrics?.uptime, $0, $1) }
        case .recentlyStarted:
            return entries.sorted {
                ascending($0.metrics?.uptime, $1.metrics?.uptime, $0, $1)
            }
        }
    }

    /// Entries we have no reading for sort last rather than as zero, so an
    /// unreadable root process never masquerades as an idle one.
    private static func descending(
        _ lhs: Double?,
        _ rhs: Double?,
        _ lhsEntry: ServerEntry,
        _ rhsEntry: ServerEntry
    ) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left == right ? lhsEntry.port < rhsEntry.port : left > right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhsEntry.port < rhsEntry.port
        }
    }

    private static func ascending(
        _ lhs: Double?,
        _ rhs: Double?,
        _ lhsEntry: ServerEntry,
        _ rhsEntry: ServerEntry
    ) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left == right ? lhsEntry.port < rhsEntry.port : left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhsEntry.port < rhsEntry.port
        }
    }

    // MARK: - Folding

    /// Collapses the sibling ports of one project or container into a single row.
    ///
    /// The primary port is the lowest non-helper port — a Vite app on 5173 with an
    /// HMR socket on 24678 shows as 5173, not as two equal rows.
    static func folded(_ entries: [ServerEntry], order: SortOrder) -> [ServerRowModel] {
        var groups: [String: [ServerEntry]] = [:]
        var groupOrder: [String] = []

        for entry in entries {
            // Only fold things that genuinely belong together. A bare process
            // keeps its own row, because two unrelated apps must never merge.
            let key = (entry.project != nil || entry.container != nil)
                ? entry.pinKey
                : "solo:\(entry.id)"

            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(entry)
        }

        let rows: [ServerRowModel] = groupOrder.compactMap { key in
            guard let members = groups[key], !members.isEmpty else { return nil }

            let ranked = members.sorted(by: PortScanner.byPortThenPID)
            guard let primary = ranked.first(where: { !$0.isLikelyHelperPort }) ?? ranked.first else {
                return nil
            }

            return ServerRowModel(
                entry: primary,
                related: ranked.filter { $0.id != primary.id }
            )
        }

        // Re-apply the sort, since folding picked representatives out of order.
        let primaries = sorted(rows.map(\.entry), by: order)
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return primaries.compactMap { rowsByID[$0.id] }
    }

    // MARK: - Sections

    static func sections(
        for entries: [ServerEntry],
        pinnedKeys: Set<String>,
        mode: GroupMode,
        order: SortOrder
    ) -> [ServerSection] {
        let pinned = entries.filter { pinnedKeys.contains($0.pinKey) }
        let rest = entries.filter { !pinnedKeys.contains($0.pinKey) }

        var sections: [ServerSection] = []

        if !pinned.isEmpty {
            sections.append(
                ServerSection(
                    id: "pinned",
                    title: "Pinned",
                    style: .pinned,
                    rows: folded(pinned, order: order)
                )
            )
        }

        switch mode {
        case .none:
            sections.append(
                ServerSection(id: "all", title: nil, style: .main, rows: folded(rest, order: order))
            )

        case .smart:
            // Abandoned servers pile up — nine dead Astro temp processes drown out
            // the three you're actually working on. They keep their own collapsed
            // sections; everything live stays flat.
            let stale = rest.filter { $0.state == .staleWorktree }
            let orphans = rest.filter { $0.state == .orphan }
            let live = rest.filter { $0.state == .active }

            if !live.isEmpty {
                sections.append(
                    ServerSection(id: "main", title: nil, style: .main, rows: folded(live, order: order))
                )
            }

            if !orphans.isEmpty {
                sections.append(
                    ServerSection(
                        id: "orphans",
                        title: "Orphans",
                        style: .orphan,
                        rows: folded(orphans, order: order)
                    )
                )
            }

            if !stale.isEmpty {
                sections.append(
                    ServerSection(
                        id: "stale",
                        title: "Stale worktrees",
                        style: .stale,
                        rows: folded(stale, order: order)
                    )
                )
            }

        case .project:
            let grouped = Dictionary(grouping: rest) { $0.project?.name ?? $0.title }
            for name in grouped.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                sections.append(
                    ServerSection(
                        id: "project:\(name)",
                        title: name,
                        style: .project,
                        rows: folded(grouped[name] ?? [], order: order)
                    )
                )
            }

        case .kind:
            for kind in ServerKind.allCases {
                let members = rest.filter { $0.kind == kind }
                guard !members.isEmpty else { continue }

                sections.append(
                    ServerSection(
                        id: "kind:\(kind.rawValue)",
                        title: kind.label,
                        style: .kind,
                        rows: folded(members, order: order)
                    )
                )
            }
        }

        return sections
    }

    // MARK: - Conflicts

    /// Ports with more than one distinct listener. Surfaced as a row badge rather
    /// than a separate section, so a conflicting server appears exactly once.
    static func conflictPorts(in entries: [ServerEntry]) -> Set<Int> {
        var seen: [Int: Set<String>] = [:]

        for entry in entries {
            seen[entry.port, default: []].insert(entry.pinKey)
        }

        return Set(seen.filter { $0.value.count > 1 }.keys)
    }
}
