import Foundation

final class PortScanner {
    func listeningProcesses() -> [ListeningProcess] {
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
                guard let port = Self.port(from: value) else { continue }
                let address = Self.address(from: value)
                current?.ports[port, default: []].insert(address)
            default:
                continue
            }
        }

        if let current, current.pid > 0 {
            snapshots.append(current)
        }

        let metadataByPID = ProjectDetector.metadataByPID(for: snapshots)
        let dockerContainersByHostPort = snapshots.contains {
            $0.command.lowercased() == "com.docker.backend"
        } ? DockerScanner.containersByHostPort() : [:]

        let rawProcesses = snapshots.flatMap { snapshot in
            snapshot.ports.map { port, addresses in
                let container = snapshot.command.lowercased() == "com.docker.backend"
                    ? dockerContainersByHostPort[port]
                    : nil

                return ListeningProcess(
                    pids: [snapshot.pid],
                    command: snapshot.command,
                    user: snapshot.user,
                    port: port,
                    addresses: Array(addresses).sorted(),
                    project: metadataByPID[snapshot.pid],
                    container: container
                )
            }
        }

        return Self.coalesced(rawProcesses).sorted {
            if $0.port == $1.port {
                return ($0.primaryPID ?? 0) < ($1.primaryPID ?? 0)
            }

            return $0.port < $1.port
        }
    }

    private static func port(from endpoint: String) -> Int? {
        if endpoint.hasPrefix("[") {
            guard let bracket = endpoint.lastIndex(of: "]") else { return nil }
            let remainder = endpoint[endpoint.index(after: bracket)...]
            guard remainder.first == ":" else { return nil }
            return Int(remainder.dropFirst())
        }

        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return Int(endpoint[endpoint.index(after: colon)...])
    }

    private static func address(from endpoint: String) -> String {
        if endpoint.hasPrefix("["), let bracket = endpoint.lastIndex(of: "]") {
            return String(endpoint[endpoint.startIndex...bracket])
        }

        guard let colon = endpoint.lastIndex(of: ":") else {
            return endpoint
        }

        return String(endpoint[..<colon])
    }

    private static func coalesced(_ processes: [ListeningProcess]) -> [ListeningProcess] {
        struct Key: Hashable {
            let command: String
            let user: String
            let port: Int
            let project: ProjectMetadata?
            let container: DockerContainer?
        }

        var pidsByKey: [Key: Set<Int32>] = [:]
        var addressesByKey: [Key: Set<String>] = [:]

        for process in processes {
            let key = Key(
                command: process.command,
                user: process.user,
                port: process.port,
                project: process.project,
                container: process.container
            )
            pidsByKey[key, default: []].formUnion(process.pids)
            addressesByKey[key, default: []].formUnion(process.addresses)
        }

        return pidsByKey.map { key, pids in
            ListeningProcess(
                pids: Array(pids).sorted(),
                command: key.command,
                user: key.user,
                port: key.port,
                addresses: Array(addressesByKey[key] ?? []).sorted(),
                project: key.project,
                container: key.container
            )
        }
    }
}
