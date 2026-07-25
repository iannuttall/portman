import Foundation

/// Maps Docker's forwarded host ports back to the containers behind them.
///
/// Without this, every container shows up as `com.docker.backend` on some port,
/// which tells you nothing and offers to kill Docker Desktop itself.
enum DockerScanner {
    /// Docker Desktop, Colima, OrbStack and Homebrew all install the CLI somewhere
    /// different. Checking one hardcoded path silently disabled the whole feature
    /// for anyone not on an Intel-era Docker Desktop install.
    private static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "/Applications/OrbStack.app/Contents/MacOS/bin/docker",
        "\(NSHomeDirectory())/.docker/bin/docker",
        "\(NSHomeDirectory())/.orbstack/bin/docker",
        "\(NSHomeDirectory())/.rd/bin/docker"
    ]

    static func executablePath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool {
        executablePath() != nil
    }

    // MARK: - Listing

    static func containersByHostPort() -> [Int: DockerContainer] {
        guard let docker = executablePath() else { return [:] }

        let format = [
            "{{.ID}}",
            "{{.Names}}",
            "{{.Image}}",
            "{{.Ports}}",
            "{{.Label \"com.docker.compose.project\"}}",
            "{{.Label \"com.docker.compose.service\"}}",
            "{{.Label \"com.docker.compose.project.working_dir\"}}"
        ].joined(separator: "\t")

        guard let output = run(docker, ["ps", "--format", format]) else { return [:] }

        return parse(output)
    }

    static func parse(_ output: String) -> [Int: DockerContainer] {
        var result: [Int: DockerContainer] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }

            let workingDirectory = fields[6].isEmpty ? nil : fields[6]

            for mapping in portMappings(from: fields[3]) {
                result[mapping.hostPort] = DockerContainer(
                    id: fields[0],
                    name: fields[1],
                    image: fields[2],
                    composeProject: fields[4].isEmpty ? nil : fields[4],
                    composeService: fields[5].isEmpty ? nil : fields[5],
                    workingDirectory: workingDirectory,
                    hostPort: mapping.hostPort,
                    containerPort: mapping.containerPort
                )
            }
        }

        return result
    }

    /// Parses the `0.0.0.0:8080->80/tcp, [::]:8080->80/tcp` shape of `docker ps`.
    static func portMappings(from ports: String) -> [(hostPort: Int, containerPort: Int?)] {
        let pattern = #"(?:(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]|\*)\:)?(\d+)->(\d+)\/tcp"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(ports.startIndex..<ports.endIndex, in: ports)
        var seen = Set<Int>()
        var mappings: [(hostPort: Int, containerPort: Int?)] = []

        for match in regex.matches(in: ports, range: range) {
            guard
                let hostRange = Range(match.range(at: 1), in: ports),
                let hostPort = Int(ports[hostRange]),
                !seen.contains(hostPort)
            else {
                continue
            }

            let containerPort = Range(match.range(at: 2), in: ports).flatMap { Int(ports[$0]) }

            seen.insert(hostPort)
            mappings.append((hostPort, containerPort))
        }

        return mappings
    }

    // MARK: - Actions

    static func stop(containerIDs: [String]) {
        guard let docker = executablePath(), !containerIDs.isEmpty else { return }
        _ = run(docker, ["stop"] + containerIDs)
    }

    // MARK: - Process

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }
}
