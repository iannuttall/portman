import Darwin
import Foundation

enum ProjectDetector {
        static func metadataByPID(for snapshots: [ProcessSnapshot]) -> [Int32: ProjectMetadata] {
            let commandNameByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0.command) })
            let pids = snapshots.map(\.pid)
            let uniquePIDs = Array(Set(pids)).sorted()
            if uniquePIDs.isEmpty {
                return [:]
            }

            let cwdByPID = cwdByPID(for: uniquePIDs)
            let commandByPID = commandByPID(for: uniquePIDs)
            var metadata: [Int32: ProjectMetadata] = [:]
            var metadataByCWD: [String: ProjectMetadata] = [:]

            for pid in uniquePIDs {
                let cwd = cwdByPID[pid]
                let command = commandByPID[pid]
                let commandName = commandNameByPID[pid]

                if !isLikelyProjectProcess(commandName: commandName, commandLine: command) {
                    continue
                }

                let inferred: ProjectMetadata

                if let cwd, let cached = metadataByCWD[cwd] {
                    inferred = cached
                } else {
                    inferred = inferProject(cwd: cwd, command: command)

                    if let cwd {
                        metadataByCWD[cwd] = inferred
                    }
                }

                if inferred.cwd != nil || inferred.root != nil || inferred.framework != nil {
                    metadata[pid] = inferred
                }
            }

            return metadata
        }

        private static func isLikelyProjectProcess(commandName: String?, commandLine: String?) -> Bool {
            let text = [commandName, commandLine]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            return [
                "node",
                "bun",
                "deno",
                "npm",
                "pnpm",
                "yarn",
                "vite",
                "next",
                "astro",
                "python",
                "ruby",
                "rails",
                "go ",
                "air",
                "cargo"
            ].contains { text.contains($0) }
        }

        private static func cwdByPID(for pids: [Int32]) -> [Int32: String] {
            var result: [Int32: String] = [:]

            for pid in pids {
                var info = proc_vnodepathinfo()
                let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
                let count = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)

                guard count == size else {
                    continue
                }

                let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        String(cString: $0)
                    }
                }

                if !path.isEmpty {
                    result[pid] = path
                }
            }

            return result
        }

        private static func commandByPID(for pids: [Int32]) -> [Int32: String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = [
                "-p",
                pids.map(String.init).joined(separator: ","),
                "-o",
                "pid=",
                "-o",
                "command="
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

            var result: [Int32: String] = [:]

            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                guard let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    continue
                }

                let pidText = String(line[..<firstSpace])
                let command = String(line[firstSpace...]).trimmingCharacters(in: .whitespaces)

                if let pid = Int32(pidText) {
                    result[pid] = command
                }
            }

            return result
        }

        private static func inferProject(cwd: String?, command: String?) -> ProjectMetadata {
            let projectRoot = cwd.flatMap(packageRoot(from:)) ?? cwd.flatMap(otherProjectRoot(from:))
            let name = projectName(root: projectRoot, cwd: cwd)
            let framework = frameworkName(root: projectRoot, cwd: cwd, command: command)
            let isOrphan = isOrphanProject(cwd: cwd, root: projectRoot, command: command)
            let isStaleWorktree = isOrphan && isAgentWorktreePath(cwd)

            return ProjectMetadata(
                cwd: cwd,
                root: projectRoot,
                name: name,
                framework: framework,
                isOrphan: isOrphan,
                isStaleWorktree: isStaleWorktree
            )
        }

        private static func packageRoot(from cwd: String) -> String? {
            firstAncestor(from: cwd, containing: "package.json")
        }

        private static func otherProjectRoot(from cwd: String) -> String? {
            for marker in ["pyproject.toml", "requirements.txt", "Gemfile", "go.mod", "Cargo.toml"] {
                if let root = firstAncestor(from: cwd, containing: marker) {
                    return root
                }
            }

            return nil
        }

        private static func firstAncestor(from cwd: String, containing filename: String) -> String? {
            if cwd.hasPrefix("/System/") || cwd.hasPrefix("/Library/") || cwd.hasPrefix("/Applications/") {
                return nil
            }

            var path = cwd
            var depth = 0

            while true {
                let candidate = "\(path)/\(filename)"
                if access(candidate, F_OK) == 0 {
                    return path
                }

                let next = URL(fileURLWithPath: path).deletingLastPathComponent().path
                depth += 1

                if next == path || next == "/" || depth >= 8 {
                    return nil
                }

                path = next
            }
        }

        private static func projectName(root: String?, cwd: String?) -> String {
            if let root, let package = packageJSON(at: root), let packageName = package["name"] as? String {
                return packageName.split(separator: "/").last.map(String.init) ?? packageName
            }

            let path = root ?? cwd
            return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
        }

        private static func frameworkName(root: String?, cwd: String?, command: String?) -> String? {
            if let root, let package = packageJSON(at: root) {
                let dependencies = packageDependencies(package)

                if hasTanStackStartSignal(root: root, dependencies: dependencies, package: package) {
                    return "TanStack Start"
                }

                if hasTanStackSignal(root: root, dependencies: dependencies, package: package) {
                    return "TanStack"
                }

                let checks: [(String, String)] = [
                    ("next", "Next.js"),
                    ("astro", "Astro"),
                    ("@remix-run/dev", "Remix"),
                    ("@sveltejs/kit", "SvelteKit"),
                    ("nuxt", "Nuxt"),
                    ("vite", "Vite"),
                    ("@angular/core", "Angular"),
                    ("react-scripts", "Create React App"),
                    ("expo", "Expo"),
                    ("electron", "Electron")
                ]

                for (dependency, name) in checks where dependencies.contains(dependency) {
                    return name
                }

                if dependencies.contains("react") {
                    return "React"
                }

                if dependencies.contains("vue") {
                    return "Vue"
                }
            }

            if let cwd, let cachedFramework = viteCacheFramework(cwd: cwd) {
                return cachedFramework
            }

            if let root, fileContains(root: root, filename: "Gemfile", needles: ["rails"]) {
                return "Rails"
            }

            if let root, fileContains(root: root, filename: "requirements.txt", needles: ["django"]) {
                return "Django"
            }

            if let root, fileContains(root: root, filename: "requirements.txt", needles: ["fastapi"]) {
                return "FastAPI"
            }

            if let command = command?.lowercased() {
                if command.contains("tanstack") {
                    return "TanStack"
                }

                if command.contains("next") {
                    return "Next.js"
                }

                if command.contains("astro") {
                    return "Astro"
                }

                if command.contains("vite") {
                    return "Vite"
                }
            }

            return nil
        }

        private static func viteCacheFramework(cwd: String) -> String? {
            let metadataPath = "\(cwd)/.vite/deps/_metadata.json"
            guard let contents = try? String(contentsOfFile: metadataPath, encoding: .utf8).lowercased() else {
                return nil
            }

            if contents.contains("@tanstack/react-start") || contents.contains("@tanstack/start") {
                return "TanStack Start"
            }

            if contents.contains("@tanstack/") {
                return "TanStack"
            }

            if contents.contains("astro") {
                return "Astro"
            }

            if contents.contains("next") {
                return "Next.js"
            }

            return nil
        }

        private static func isOrphanProject(cwd: String?, root: String?, command: String?) -> Bool {
            guard let cwd else {
                return false
            }

            if access(cwd, F_OK) != 0 {
                return true
            }

            guard root == nil else {
                return false
            }

            let lowerCommand = command?.lowercased() ?? ""

            return [
                "/node_modules/",
                "node_modules/.bin",
                "vite",
                "next",
                "astro",
                "tanstack",
                "npm ",
                "pnpm ",
                "yarn ",
                "bun ",
                "deno "
            ].contains { lowerCommand.contains($0) }
        }

        private static func isAgentWorktreePath(_ cwd: String?) -> Bool {
            guard let cwd else {
                return false
            }

            let lower = cwd.lowercased()
            return [
                "/conductor/workspaces/",
                "/claude/workspaces/",
                "/codex/workspaces/",
                "/.codex/workspaces/",
                "/.claude/workspaces/"
            ].contains { lower.contains($0) }
        }

        private static func hasTanStackStartSignal(
            root: String,
            dependencies: Set<String>,
            package: [String: Any]
        ) -> Bool {
            if dependencies.contains("@tanstack/start") || dependencies.contains("@tanstack/react-start") {
                return true
            }

            if packageScripts(package).contains(where: { $0.contains("tanstack") && $0.contains("start") }) {
                return true
            }

            return projectFilesContain(
                root: root,
                filenames: [
                    "app.config.ts",
                    "app.config.js",
                    "app.config.mjs",
                    "vite.config.ts",
                    "vite.config.js",
                    "vite.config.mjs",
                    "src/router.tsx",
                    "src/router.ts",
                    "app/router.tsx",
                    "app/router.ts"
                ],
                needles: [
                    "@tanstack/react-start",
                    "@tanstack/start",
                    "tanstackStart",
                    "createStart"
                ]
            )
        }

        private static func hasTanStackSignal(
            root: String,
            dependencies: Set<String>,
            package: [String: Any]
        ) -> Bool {
            if dependencies.contains(where: { $0.hasPrefix("@tanstack/") }) {
                return true
            }

            if packageScripts(package).contains(where: { $0.contains("tanstack") }) {
                return true
            }

            return projectFilesContain(
                root: root,
                filenames: [
                    "vite.config.ts",
                    "vite.config.js",
                    "vite.config.mjs",
                    "tsr.config.json",
                    "src/router.tsx",
                    "src/router.ts",
                    "app/router.tsx",
                    "app/router.ts",
                    "src/routeTree.gen.ts",
                    "app/routeTree.gen.ts"
                ],
                needles: [
                    "@tanstack/",
                    "createRouter",
                    "createFileRoute",
                    "TanStackRouter"
                ]
            )
        }

        private static func packageJSON(at root: String) -> [String: Any]? {
            let url = URL(fileURLWithPath: root).appendingPathComponent("package.json")

            guard
                let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            return json
        }

        private static func packageDependencies(_ package: [String: Any]) -> Set<String> {
            var dependencies = Set<String>()

            for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
                guard let values = package[key] as? [String: Any] else { continue }
                dependencies.formUnion(values.keys)
            }

            return dependencies
        }

        private static func packageScripts(_ package: [String: Any]) -> [String] {
            guard let scripts = package["scripts"] as? [String: Any] else {
                return []
            }

            return scripts.values.compactMap { ($0 as? String)?.lowercased() }
        }

        private static func projectFilesContain(root: String, filenames: [String], needles: [String]) -> Bool {
            for filename in filenames {
                if fileContains(root: root, filename: filename, needles: needles) {
                    return true
                }
            }

            return false
        }

        private static func fileContains(root: String, filename: String, needles: [String]) -> Bool {
            let url = URL(fileURLWithPath: root).appendingPathComponent(filename)
            guard let contents = try? String(contentsOf: url, encoding: .utf8).lowercased() else {
                return false
            }

            return needles.contains { contents.contains($0) }
        }
}
