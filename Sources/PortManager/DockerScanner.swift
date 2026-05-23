import Foundation

enum DockerScanner {
        static func containersByHostPort() -> [Int: DockerContainer] {
            guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/docker") else {
                return [:]
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
            process.arguments = [
                "ps",
                "--format",
                "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}"
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return [:]
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                return [:]
            }

            var result: [Int: DockerContainer] = [:]

            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 7 else { continue }

                let id = fields[0]
                let name = fields[1]
                let image = fields[2]
                let ports = fields[3]
                let composeProject = fields[4].isEmpty ? nil : fields[4]
                let composeService = fields[5].isEmpty ? nil : fields[5]
                let workingDirectory = fields[6].isEmpty ? nil : fields[6]

                for mapping in dockerPortMappings(from: ports) {
                    result[mapping.hostPort] = DockerContainer(
                        id: id,
                        name: name,
                        image: image,
                        composeProject: composeProject,
                        composeService: composeService,
                        workingDirectory: workingDirectory,
                        hostPort: mapping.hostPort,
                        containerPort: mapping.containerPort
                    )
                }
            }

            return result
        }

        private static func dockerPortMappings(from ports: String) -> [(hostPort: Int, containerPort: Int?)] {
            let pattern = #"(?:(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]|\*)\:)?(\d+)->(\d+)\/tcp"#

            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return []
            }

            let range = NSRange(ports.startIndex..<ports.endIndex, in: ports)
            let matches = regex.matches(in: ports, range: range)
            var seen = Set<Int>()
            var mappings: [(hostPort: Int, containerPort: Int?)] = []

            for match in matches {
                guard
                    let hostRange = Range(match.range(at: 1), in: ports),
                    let hostPort = Int(ports[hostRange])
                else {
                    continue
                }

                if seen.contains(hostPort) {
                    continue
                }

                let containerPort: Int?
                if let containerRange = Range(match.range(at: 2), in: ports) {
                    containerPort = Int(ports[containerRange])
                } else {
                    containerPort = nil
                }

                seen.insert(hostPort)
                mappings.append((hostPort, containerPort))
            }

            return mappings
        }
}
