import Foundation

/// Turns `lsof` output into enriched `ServerEntry` values.
///
/// Runs entirely off the main actor — every call here shells out or hits the
/// filesystem, and the panel must stay responsive while it does.
struct PortScanner: Sendable {
    func scan() -> [ServerEntry] {
        let snapshots = Self.snapshots()
        guard !snapshots.isEmpty else { return [] }

        let metadataByPID = ProjectDetector.metadataByPID(for: snapshots)
        let needsDocker = snapshots.contains { $0.command.lowercased() == "com.docker.backend" }
        let containersByHostPort = needsDocker ? DockerScanner.containersByHostPort() : [:]

        let entries = snapshots.flatMap { snapshot in
            snapshot.ports.map { port, addresses in
                let container = snapshot.command.lowercased() == "com.docker.backend"
                    ? containersByHostPort[port]
                    : nil

                return ServerEntry(
                    port: port,
                    pids: [snapshot.pid],
                    command: snapshot.command,
                    user: snapshot.user,
                    addresses: addresses.sorted(),
                    project: metadataByPID[snapshot.pid],
                    container: container
                )
            }
        }

        return Self.coalesced(entries).sorted(by: Self.byPortThenPID)
    }

    // MARK: - lsof

    static func snapshots() -> [ProcessSnapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return parse(output)
    }

    /// Parses `lsof -F` field output: one field per line, first character is the
    /// field tag, and a `p` line starts a new process record.
    static func parse(_ output: String) -> [ProcessSnapshot] {
        var snapshots: [ProcessSnapshot] = []
        var current: ProcessSnapshot?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                if let current, current.pid > 0 {
                    snapshots.append(current)
                }

                current = ProcessSnapshot(pid: Int32(value) ?? 0)
            case "c":
                current?.command = value
            case "L":
                current?.user = value
            case "n":
                guard let port = port(from: value) else { continue }
                current?.ports[port, default: []].insert(address(from: value))
            default:
                continue
            }
        }

        if let current, current.pid > 0 {
            snapshots.append(current)
        }

        return snapshots
    }

    /// Handles both `127.0.0.1:3000` and the bracketed IPv6 form `[::1]:3000`.
    static func port(from endpoint: String) -> Int? {
        if endpoint.hasPrefix("[") {
            guard let bracket = endpoint.lastIndex(of: "]") else { return nil }
            let remainder = endpoint[endpoint.index(after: bracket)...]
            guard remainder.first == ":" else { return nil }
            return Int(remainder.dropFirst())
        }

        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return Int(endpoint[endpoint.index(after: colon)...])
    }

    static func address(from endpoint: String) -> String {
        if endpoint.hasPrefix("["), let bracket = endpoint.lastIndex(of: "]") {
            return String(endpoint[endpoint.startIndex...bracket])
        }

        guard let colon = endpoint.lastIndex(of: ":") else {
            return endpoint
        }

        return String(endpoint[..<colon])
    }

    // MARK: - Coalescing

    /// One server bound to both IPv4 and IPv6 shows up as several `lsof` rows.
    /// Merge anything that agrees on command, user, port, project and container
    /// so the list shows one row per actual listener.
    static func coalesced(_ entries: [ServerEntry]) -> [ServerEntry] {
        struct Key: Hashable {
            let command: String
            let user: String
            let port: Int
            let project: ProjectMetadata?
            let container: DockerContainer?
        }

        var pidsByKey: [Key: Set<Int32>] = [:]
        var addressesByKey: [Key: Set<String>] = [:]
        var order: [Key] = []

        for entry in entries {
            let key = Key(
                command: entry.command,
                user: entry.user,
                port: entry.port,
                project: entry.project,
                container: entry.container
            )

            if pidsByKey[key] == nil {
                order.append(key)
            }

            pidsByKey[key, default: []].formUnion(entry.pids)
            addressesByKey[key, default: []].formUnion(entry.addresses)
        }

        return order.map { key in
            ServerEntry(
                port: key.port,
                pids: (pidsByKey[key] ?? []).sorted(),
                command: key.command,
                user: key.user,
                addresses: (addressesByKey[key] ?? []).sorted(),
                project: key.project,
                container: key.container
            )
        }
    }

    static func byPortThenPID(_ lhs: ServerEntry, _ rhs: ServerEntry) -> Bool {
        if lhs.port == rhs.port {
            return (lhs.primaryPID ?? 0) < (rhs.primaryPID ?? 0)
        }

        return lhs.port < rhs.port
    }
}
