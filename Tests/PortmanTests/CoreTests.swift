import XCTest

@testable import Portman

// MARK: - lsof parsing

final class PortScannerTests: XCTestCase {
    func testParsesFieldOutputIntoSnapshots() {
        let output = """
        p1234
        cnode
        Liannuttall
        n127.0.0.1:3000
        n[::1]:3000
        p5678
        cpostgres
        Lpostgres
        n*:5432
        """

        let snapshots = PortScanner.parse(output)

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].pid, 1234)
        XCTAssertEqual(snapshots[0].command, "node")
        XCTAssertEqual(snapshots[0].user, "iannuttall")
        XCTAssertEqual(Set(snapshots[0].ports.keys), [3000])
        XCTAssertEqual(snapshots[0].ports[3000], ["127.0.0.1", "[::1]"])
        XCTAssertEqual(snapshots[1].ports[5432], ["*"])
    }

    func testIgnoresRecordsWithoutAPID() {
        XCTAssertTrue(PortScanner.parse("cnode\nn127.0.0.1:3000").isEmpty)
    }

    func testParsesIPv6Endpoints() {
        XCTAssertEqual(PortScanner.port(from: "[::1]:8080"), 8080)
        XCTAssertEqual(PortScanner.address(from: "[::1]:8080"), "[::1]")
        XCTAssertEqual(PortScanner.port(from: "[fe80::1%en0]:443"), 443)
    }

    func testParsesIPv4Endpoints() {
        XCTAssertEqual(PortScanner.port(from: "127.0.0.1:3000"), 3000)
        XCTAssertEqual(PortScanner.address(from: "127.0.0.1:3000"), "127.0.0.1")
        XCTAssertEqual(PortScanner.port(from: "*:5432"), 5432)
    }

    func testRejectsMalformedEndpoints() {
        XCTAssertNil(PortScanner.port(from: "127.0.0.1"))
        XCTAssertNil(PortScanner.port(from: "[::1]"))
        XCTAssertNil(PortScanner.port(from: "127.0.0.1:notaport"))
    }

    /// One server bound to IPv4 and IPv6 must collapse into a single row.
    func testCoalescesDualStackListeners() {
        let entries = [
            makeEntry(port: 3000, pids: [100], addresses: ["127.0.0.1"]),
            makeEntry(port: 3000, pids: [100], addresses: ["[::1]"])
        ]

        let coalesced = PortScanner.coalesced(entries)

        XCTAssertEqual(coalesced.count, 1)
        XCTAssertEqual(coalesced[0].addresses, ["127.0.0.1", "[::1]"])
    }

    func testKeepsDistinctCommandsOnTheSamePortApart() {
        let entries = [
            makeEntry(port: 5432, pids: [100], command: "postgres"),
            makeEntry(port: 5432, pids: [200], command: "com.docker.backend")
        ]

        XCTAssertEqual(PortScanner.coalesced(entries).count, 2)
    }
}

// MARK: - Docker

final class DockerScannerTests: XCTestCase {
    func testParsesForwardedPortMappings() {
        let mappings = DockerScanner.portMappings(from: "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp")

        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings[0].hostPort, 8080)
        XCTAssertEqual(mappings[0].containerPort, 80)
    }

    func testParsesMultipleDistinctMappings() {
        let mappings = DockerScanner.portMappings(from: "127.0.0.1:5432->5432/tcp, 0.0.0.0:6379->6379/tcp")

        XCTAssertEqual(mappings.map(\.hostPort), [5432, 6379])
    }

    func testIgnoresUnpublishedPorts() {
        XCTAssertTrue(DockerScanner.portMappings(from: "5432/tcp").isEmpty)
        XCTAssertTrue(DockerScanner.portMappings(from: "").isEmpty)
    }

    func testParsesPSRowsIntoContainers() {
        let row = [
            "abc123", "ianis-db-1", "postgres:16", "0.0.0.0:5432->5432/tcp",
            "ianis", "db", "/Users/someone/code/ian.is"
        ].joined(separator: "\t")

        let containers = DockerScanner.parse(row)

        XCTAssertEqual(containers[5432]?.displayName, "ianis/db")
        XCTAssertEqual(containers[5432]?.image, "postgres:16")
        XCTAssertEqual(containers[5432]?.containerPort, 5432)
    }
}

// MARK: - Search

final class SearchTests: XCTestCase {
    func testMatchesOnPortProjectAndFramework() {
        let entry = makeEntry(port: 4321, project: project(name: "web", framework: "Astro"))

        XCTAssertTrue(ListShaper.matches(entry, query: "4321"))
        XCTAssertTrue(ListShaper.matches(entry, query: "web"))
        XCTAssertTrue(ListShaper.matches(entry, query: "astro"))
        XCTAssertFalse(ListShaper.matches(entry, query: "nextjs"))
    }

    func testEveryTokenMustMatch() {
        let entry = makeEntry(port: 4321, project: project(name: "web", framework: "Astro"))

        XCTAssertTrue(ListShaper.matches(entry, query: "astro web"))
        XCTAssertFalse(ListShaper.matches(entry, query: "astro postgres"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(ListShaper.matches(makeEntry(port: 3000), query: ""))
        XCTAssertTrue(ListShaper.matches(makeEntry(port: 3000), query: "   "))
    }

    /// `/pattern/` is how "kill regexp" is expressed.
    func testSlashDelimitedQueriesRunAsRegex() {
        let entry = makeEntry(port: 4321, project: project(name: "web", framework: "Astro"))

        XCTAssertTrue(ListShaper.matches(entry, query: "/43[0-9]{2}.*astro/"))
        XCTAssertTrue(ListShaper.matches(entry, query: "/^4321/"))
        XCTAssertTrue(ListShaper.matches(entry, query: "/astro|nuxt/"))
        XCTAssertFalse(ListShaper.matches(entry, query: "/^999/"))
    }

    func testInvalidRegexMatchesNothingRatherThanEverything() {
        XCTAssertFalse(ListShaper.matches(makeEntry(port: 3000), query: "/[unclosed/"))
    }

    func testBareSlashesAreNotTreatedAsRegex() {
        let entry = makeEntry(port: 3000, project: project(name: "api", framework: nil))

        // A lone "/" is a path fragment someone is typing, not a pattern.
        XCTAssertNil(ListShaper.regexPattern(in: "/"))
        XCTAssertNil(ListShaper.regexPattern(in: "//"))
        XCTAssertFalse(ListShaper.matches(entry, query: "/nope/"))
    }

    func testSearchesPageTitleAndBranch() {
        var entry = makeEntry(port: 3000)
        entry.health = HealthReport(state: .healthy, pageTitle: "Acme Store")
        entry.git = GitStatus(branch: "feat/checkout")

        XCTAssertTrue(ListShaper.matches(entry, query: "acme"))
        XCTAssertTrue(ListShaper.matches(entry, query: "checkout"))
    }
}

// MARK: - Sorting

final class SortingTests: XCTestCase {
    func testSortsByPortAscending() {
        let entries = [makeEntry(port: 5432), makeEntry(port: 3000), makeEntry(port: 8080)]

        XCTAssertEqual(ListShaper.sorted(entries, by: .port).map(\.port), [3000, 5432, 8080])
    }

    func testSortsByCPUDescending() {
        let entries = [
            makeEntry(port: 3000, cpu: 2),
            makeEntry(port: 4000, cpu: 90),
            makeEntry(port: 5000, cpu: 40)
        ]

        XCTAssertEqual(ListShaper.sorted(entries, by: .cpu).map(\.port), [4000, 5000, 3000])
    }

    /// An unreadable root process has no CPU reading. It must sort last rather
    /// than pretending to be idle at 0%.
    func testEntriesWithoutReadingsSortLast() {
        let entries = [
            makeEntry(port: 3000),
            makeEntry(port: 4000, cpu: 5),
            makeEntry(port: 5000)
        ]

        XCTAssertEqual(ListShaper.sorted(entries, by: .cpu).map(\.port), [4000, 3000, 5000])
    }
}

// MARK: - Folding

final class FoldingTests: XCTestCase {
    /// A Vite app on 5173 with an HMR socket on 24678 is one row, not two.
    func testFoldsSiblingPortsOntoTheAppPort() {
        let metadata = project(name: "web", framework: "Vite")
        let entries = [
            makeEntry(port: 5173, pids: [1], project: metadata),
            makeEntry(port: 24678, pids: [1], project: metadata)
        ]

        let rows = ListShaper.folded(entries, order: .port)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].entry.port, 5173)
        XCTAssertEqual(rows[0].related.map(\.port), [24678])
        XCTAssertEqual(rows[0].portCount, 2)
    }

    func testNeverMergesUnrelatedProcesses() {
        let entries = [
            makeEntry(port: 5432, pids: [1], command: "postgres"),
            makeEntry(port: 6379, pids: [2], command: "redis")
        ]

        XCTAssertEqual(ListShaper.folded(entries, order: .port).count, 2)
    }

    func testKeepsSeparateProjectsSeparate() {
        let entries = [
            makeEntry(port: 3000, pids: [1], project: project(name: "shop", framework: "Next.js")),
            makeEntry(port: 4321, pids: [2], project: project(name: "blog", framework: "Astro"))
        ]

        XCTAssertEqual(ListShaper.folded(entries, order: .port).count, 2)
    }
}

// MARK: - Conflicts

final class ConflictTests: XCTestCase {
    func testFlagsPortsWithTwoDistinctListeners() {
        let entries = [
            makeEntry(port: 5432, pids: [1], command: "postgres"),
            makeEntry(port: 5432, pids: [2], command: "com.docker.backend"),
            makeEntry(port: 6379, pids: [3], command: "redis")
        ]

        XCTAssertEqual(ListShaper.conflictPorts(in: entries), [5432])
    }

    /// The same project holding one port twice is dual-stack binding, not a clash.
    func testDoesNotFlagOneListenerBoundTwice() {
        let metadata = project(name: "web", framework: "Astro")
        let entries = [
            makeEntry(port: 4321, pids: [1], project: metadata),
            makeEntry(port: 4321, pids: [1], project: metadata)
        ]

        XCTAssertTrue(ListShaper.conflictPorts(in: entries).isEmpty)
    }
}

// MARK: - Classification

final class ClassificationTests: XCTestCase {
    func testClassifiesByProjectContainerAndCommand() {
        XCTAssertEqual(makeEntry(port: 4321, project: project(name: "web", framework: "Astro")).kind, .dev)
        XCTAssertEqual(makeEntry(port: 5432, command: "postgres").kind, .database)
        XCTAssertEqual(makeEntry(port: 80, command: "nginx").kind, .system)
        XCTAssertEqual(makeEntry(port: 7777, command: "mystery").kind, .other)
    }

    func testHidesSystemPortsButNeverOrphans() {
        XCTAssertTrue(makeEntry(port: 80, command: "nginx").hiddenByDefault)

        let orphan = makeEntry(
            port: 80,
            project: project(name: "gone", framework: "Astro", isOrphan: true)
        )
        XCTAssertFalse(orphan.hiddenByDefault)
    }

    func testTreatsDebugAndEphemeralPortsAsHelpers() {
        XCTAssertTrue(makeEntry(port: 9229).isLikelyHelperPort)
        XCTAssertTrue(makeEntry(port: 51000).isLikelyHelperPort)
        XCTAssertFalse(makeEntry(port: 3000).isLikelyHelperPort)
    }

    func testIdentityIsStableAcrossScansAndChangesOnRestart() {
        XCTAssertEqual(makeEntry(port: 3000, pids: [42]).id, makeEntry(port: 3000, pids: [42]).id)
        XCTAssertNotEqual(makeEntry(port: 3000, pids: [42]).id, makeEntry(port: 3000, pids: [43]).id)
    }

    func testHungServersCountAsIssues() {
        var entry = makeEntry(port: 3000)
        entry.health = HealthReport(state: .hung)
        XCTAssertTrue(entry.hasIssue)

        entry.health = HealthReport(state: .healthy)
        XCTAssertFalse(entry.hasIssue)
    }
}

// MARK: - Exposure

final class ExposureTests: XCTestCase {
    func testLoopbackBindsAreThisMacOnly() {
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["127.0.0.1"]).exposure, .loopback)
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["[::1]"]).exposure, .loopback)
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["127.0.0.1", "[::1]"]).exposure, .loopback)
    }

    func testWildcardBindsAreReachableOnTheNetwork() {
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["*"]).exposure, .network)
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["0.0.0.0"]).exposure, .network)
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["[::]"]).exposure, .network)
    }

    func testSpecificInterfaceBindsAreReachableOnTheNetwork() {
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["192.168.1.5"]).exposure, .network)
    }

    /// One loopback binding doesn't make a wildcard binding safe.
    func testMixedBindsResolveToTheWiderExposure() {
        XCTAssertEqual(makeEntry(port: 3000, addresses: ["127.0.0.1", "0.0.0.0"]).exposure, .network)
    }
}

// MARK: - Ancestry

final class ProcessAncestryTests: XCTestCase {
    func testTrustsShellsAndCodingAgentsByExecutableName() {
        XCTAssertTrue(ProcessAncestry.isDeveloperTool(name: "zsh", path: nil))
        XCTAssertTrue(ProcessAncestry.isDeveloperTool(name: "claude", path: nil))
        XCTAssertTrue(ProcessAncestry.isDeveloperTool(name: nil, path: "/Users/x/.bun/bin/opencode"))
    }

    func testTrustsToolsRunningInsideTheirAppBundle() {
        XCTAssertTrue(ProcessAncestry.isDeveloperTool(
            name: "node",
            path: "/Applications/Cursor.app/Contents/MacOS/node"
        ))
        XCTAssertTrue(ProcessAncestry.isDeveloperTool(
            name: nil,
            path: "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        ))
    }

    /// `zed`, `warp`, `kitty` and `goose` are ordinary words. Matching them as bare path
    /// tokens promotes anything living in a directory that happens to contain one.
    func testDoesNotTrustToolNamesAppearingIncidentallyInAPath() {
        XCTAssertFalse(ProcessAncestry.isDeveloperTool(
            name: "python3",
            path: "/Users/x/dev/zed-experiments/server.py"
        ))
        XCTAssertFalse(ProcessAncestry.isDeveloperTool(
            name: "node",
            path: "/Users/x/projects/kitty-cam/index.js"
        ))
        XCTAssertFalse(ProcessAncestry.isDeveloperTool(
            name: "ruby",
            path: "/Users/x/code/goose-tracker/app.rb"
        ))
    }

    func testDoesNotTrustOrdinarySystemDaemons() {
        XCTAssertFalse(ProcessAncestry.isDeveloperTool(name: "launchd", path: "/sbin/launchd"))
        XCTAssertFalse(ProcessAncestry.isDeveloperTool(name: "rapportd", path: "/usr/libexec/rapportd"))
    }
}

// MARK: - Formatting

final class FormatTests: XCTestCase {
    func testFormatsUptimeAcrossScales() {
        XCTAssertEqual(Format.uptime(45), "45s")
        XCTAssertEqual(Format.uptime(90), "1m")
        XCTAssertEqual(Format.uptime(3600 * 4 + 60 * 12), "4h 12m")
        XCTAssertEqual(Format.uptime(3600 * 26), "1d 2h")
    }

    func testFormatsMemoryInHumanUnits() {
        XCTAssertEqual(Format.memory(512 * 1_048_576), "512 MB")
        XCTAssertEqual(Format.memory(2 * 1024 * 1_048_576), "2.0 GB")
    }

    func testFormatsCPUWithPrecisionOnlyWhereItMatters() {
        XCTAssertEqual(Format.cpu(2.14), "2.1%")
        XCTAssertEqual(Format.cpu(84.6), "85%")
    }
}

// MARK: - Fixtures

private func project(
    name: String,
    framework: String?,
    isOrphan: Bool = false,
    isStaleWorktree: Bool = false
) -> ProjectMetadata {
    ProjectMetadata(
        cwd: "/Users/test/dev/\(name)",
        root: "/Users/test/dev/\(name)",
        name: name,
        framework: framework,
        isOrphan: isOrphan,
        isStaleWorktree: isStaleWorktree
    )
}

private func makeEntry(
    port: Int,
    pids: [Int32] = [1],
    command: String = "node",
    addresses: [String] = ["127.0.0.1"],
    project: ProjectMetadata? = nil,
    cpu: Double? = nil
) -> ServerEntry {
    ServerEntry(
        port: port,
        pids: pids,
        command: command,
        user: "test",
        addresses: addresses,
        project: project,
        container: nil,
        metrics: cpu.map { ProcessSample(cpuPercent: $0) }
    )
}

// MARK: - Tunnels

final class TunnelURLTests: XCTestCase {
    /// cloudflared prints the URL inside an ASCII banner, not on a line of its own.
    func testExtractsURLFromABannerLine() {
        let line = "|  https://random-words-here.trycloudflare.com                     |"
        XCTAssertEqual(
            TunnelService.extractURL(from: line),
            "https://random-words-here.trycloudflare.com"
        )
    }

    func testExtractsURLFromALogLine() {
        let line = "2026-07-25T09:30:00Z INF +----+ Your quick Tunnel has been created! Visit it at https://abc-def-123.trycloudflare.com"
        XCTAssertEqual(
            TunnelService.extractURL(from: line),
            "https://abc-def-123.trycloudflare.com"
        )
    }

    func testIgnoresUnrelatedLines() {
        XCTAssertNil(TunnelService.extractURL(from: "INF Requesting new quick Tunnel on trycloudflare.com..."))
        XCTAssertNil(TunnelService.extractURL(from: "https://example.com"))
        XCTAssertNil(TunnelService.extractURL(from: ""))
    }
}
