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
    let projectQualifier: String?

    init(entry: ServerEntry, related: [ServerEntry], projectQualifier: String? = nil) {
        self.entry = entry
        self.related = related
        self.projectQualifier = projectQualifier
    }

    var id: String { entry.id }

    var allPIDs: [Int32] {
        Array(Set(([entry] + related).flatMap(\.pids))).sorted()
    }

    var portCount: Int { related.count + 1 }
}

/// One thing currently worth interrupting someone about, in the form the status item
/// needs it: what kind, which port, and what to call it.
struct ServerIssue: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case conflict
        case stale
        case orphan
        case hung
    }

    let kind: Kind
    let port: Int
    let name: String

    /// Stable for as long as it's the same problem, so the status item can tell a new
    /// issue from one it has already flagged and only pull the eye once per problem.
    var id: String { "\(kind.rawValue):\(port)" }

    /// Written as a finding rather than a label. This ends up in the status item's
    /// tooltip, which is the only place the menu bar has room to say what's wrong,
    /// and "1 issue" would only tell you to go looking for it.
    var sentence: String {
        switch kind {
        case .conflict: return "Port \(port) has more than one listener"
        case .stale: return "\(name) on \(port) is from a worktree that's been deleted"
        case .orphan: return "\(name) on \(port) has lost its project folder"
        case .hung: return "\(name) on \(port) accepts connections but never answers"
        }
    }
}

struct ServerSection: Identifiable, Hashable, Sendable {
    enum Style: String, Sendable, Hashable {
        case pinned
        case conflict
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
            // Contested ports come first and are pulled out of the main list.
            //
            // A `conflict` chip on a row tells you there's a clash but not what with,
            // and under any sort other than by port the rivals scatter. Sitting them
            // together, always ordered by port, is what makes the choice obvious —
            // you compare the two candidates side by side and kill one.
            let contested = conflictPorts(in: rest)
            let conflicting = rest.filter { contested.contains($0.port) }
            let uncontested = rest.filter { !contested.contains($0.port) }

            // One section per contested port. The port becomes the heading and the
            // rivals sit underneath it, so the comparison you have to make — which
            // of these two do I keep — is the thing on screen.
            for port in Set(conflicting.map(\.port)).sorted() {
                let rivals = conflicting.filter { $0.port == port }

                sections.append(
                    ServerSection(
                        id: "conflict:\(port)",
                        title: "Conflict on :\(port)",
                        style: .conflict,
                        rows: folded(rivals, order: .port)
                    )
                )
            }

            // Abandoned servers pile up — nine dead Astro temp processes drown out
            // the three you're actually working on. They keep their own collapsed
            // sections; everything live stays flat.
            let stale = uncontested.filter { $0.state == .staleWorktree }
            let orphans = uncontested.filter { $0.state == .orphan }
            let live = uncontested.filter { $0.state == .active }

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

        return disambiguateProjectNames(in: sections)
    }

    /// Package names such as `site` and `app` are common inside monorepos. When
    /// more than one visible project has the same name, prefix each with the
    /// shortest useful part of its path: `ian.is / site`, not the full root.
    private static func disambiguateProjectNames(in sections: [ServerSection]) -> [ServerSection] {
        let rows = sections.flatMap(\.rows)
        let duplicates = Dictionary(grouping: rows) { $0.entry.title.lowercased() }
            .filter { _, rows in
                Set(rows.compactMap { $0.entry.project?.path }).count > 1
            }

        var qualifiers: [String: String] = [:]

        for rows in duplicates.values {
            let candidates = rows.compactMap { row -> (String, [String])? in
                guard let project = row.entry.project, let path = project.path else { return nil }
                return (row.id, projectContextComponents(path: path, name: project.name))
            }

            for (id, components) in candidates {
                guard !components.isEmpty else { continue }

                for length in 1...components.count {
                    let suffix = components.suffix(length)
                    let isUnique = candidates.filter { _, other in
                        other.suffix(length) == suffix
                    }.count == 1

                    if isUnique || length == components.count {
                        qualifiers[id] = suffix.joined(separator: " / ")
                        break
                    }
                }
            }
        }

        return sections.map { section in
            ServerSection(
                id: section.id,
                title: section.title,
                style: section.style,
                rows: section.rows.map { row in
                    ServerRowModel(
                        entry: row.entry,
                        related: row.related,
                        projectQualifier: qualifiers[row.id]
                    )
                }
            )
        }
    }

    private static func projectContextComponents(path: String, name: String) -> [String] {
        var components = URL(fileURLWithPath: path).standardized.pathComponents
            .filter { $0 != "/" }

        if components.last?.localizedCaseInsensitiveCompare(name) == .orderedSame {
            components.removeLast()
        }

        // These describe a monorepo's layout, not the project containing it.
        if let last = components.last?.lowercased(), ["apps", "packages", "services"].contains(last) {
            components.removeLast()
        }

        return components
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

    // MARK: - Issues

    /// Everything wrong right now, worst first: a contested port breaks the next
    /// request you make, where an abandoned server only wastes the machine.
    ///
    /// At most one issue per port. Both halves of a conflict are the same conflict, and
    /// a stale worktree holding a contested port is usually the *cause* of that conflict
    /// — one kill fixes both, so counting it twice would overstate how much is wrong.
    static func issues(in entries: [ServerEntry], contestedPorts: Set<Int>) -> [ServerIssue] {
        var issues: [ServerIssue] = []
        var claimed: Set<Int> = []

        for port in contestedPorts.sorted() {
            guard let name = entries.first(where: { $0.port == port })?.title else { continue }
            issues.append(ServerIssue(kind: .conflict, port: port, name: name))
            claimed.insert(port)
        }

        for entry in entries.sorted(by: { $0.port < $1.port }) where !claimed.contains(entry.port) {
            let kind: ServerIssue.Kind? = switch entry.state {
            case .staleWorktree: .stale
            case .orphan: .orphan
            case .active: entry.health?.state == .hung ? .hung : nil
            }

            guard let kind else { continue }
            issues.append(ServerIssue(kind: kind, port: entry.port, name: entry.title))
            claimed.insert(entry.port)
        }

        return issues
    }
}
