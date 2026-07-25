import Foundation

enum TunnelError: LocalizedError {
    case notInstalled
    case alreadyRunning
    case timedOut
    case ended(String?)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "cloudflared isn't installed. Install it with `brew install cloudflared`."
        case .alreadyRunning:
            return "That port is already shared."
        case .timedOut:
            return "cloudflared didn't return a URL in time."
        case .ended(let detail):
            return detail ?? "cloudflared stopped before the tunnel came up."
        }
    }
}

/// Puts a local port on the public internet through a Cloudflare quick tunnel.
///
/// `cloudflared tunnel --url localhost:3000` prints a `*.trycloudflare.com` address
/// to stdout and holds the tunnel open until the process dies — so a tunnel's
/// lifetime is exactly its process's lifetime, and stopping one is a kill.
///
/// Quick tunnels need no Cloudflare account and no DNS, which is why they're worth
/// having and named tunnels aren't.
actor TunnelService {
    private var processes: [Int: Process] = [:]
    private var readers: [Int: Task<Void, Never>] = [:]
    private var urls: [Int: String] = [:]
    private var waiters: [Int: CheckedContinuation<String, Error>] = [:]
    private var lastError: [Int: String] = [:]

    private static let searchPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared"
    ]

    static func executablePath() -> String? {
        if let custom = Preferences.cloudflaredPath,
           !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }

        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool {
        executablePath() != nil
    }

    /// `https://<something>.trycloudflare.com`, wherever it appears in the log line —
    /// cloudflared prints it inside an ASCII banner, not on a line of its own.
    static func extractURL(from line: String) -> String? {
        let pattern = #"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com"#

        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ),
            let range = Range(match.range, in: line)
        else {
            return nil
        }

        return String(line[range])
    }

    /// Note the `=` form: cloudflared rejects `--http-host-header <value>` as a
    /// separate argument and prints its help instead of starting.
    static func arguments(for port: Int) -> [String] {
        var arguments = ["tunnel", "--url", "http://localhost:\(port)"]

        if Preferences.rewriteTunnelHost {
            arguments.append("--http-host-header=localhost:\(port)")
        }

        return arguments
    }

    // MARK: - Lifecycle

    /// Kills tunnels left behind by a previous run.
    ///
    /// A quick tunnel dies with its process, so a crash leaves an orphan holding a
    /// public URL that nothing in the UI knows about any more.
    static func killOrphans() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "cloudflared.*tunnel.*--url"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    func start(port: Int, timeout: TimeInterval = 25) async throws -> String {
        guard let path = Self.executablePath() else { throw TunnelError.notInstalled }

        if let existing = processes[port], existing.isRunning {
            if let url = urls[port] { return url }
            throw TunnelError.alreadyRunning
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Self.arguments(for: port)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        processes[port] = process
        beginReading(port: port, handle: pipe.fileHandleForReading)

        scheduleTimeout(port: port, after: timeout)

        return try await withCheckedThrowingContinuation { continuation in
            if let url = urls[port] {
                continuation.resume(returning: url)
                return
            }

            waiters[port] = continuation
        }
    }

    func stop(port: Int) {
        readers.removeValue(forKey: port)?.cancel()

        if let process = processes.removeValue(forKey: port), process.isRunning {
            process.terminate()
        }

        urls.removeValue(forKey: port)
        lastError.removeValue(forKey: port)
        waiters.removeValue(forKey: port)?.resume(throwing: TunnelError.ended(nil))
    }

    func stopAll() {
        for port in processes.keys {
            stop(port: port)
        }
    }

    func url(for port: Int) -> String? {
        urls[port]
    }

    // MARK: - Output

    /// Drains cloudflared's output for the whole life of the tunnel.
    ///
    /// It has to keep draining after the URL is found: stop reading and the pipe
    /// buffer fills, which blocks cloudflared and takes the tunnel down with it.
    private func beginReading(port: Int, handle: FileHandle) {
        readers[port] = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.consume(line: line, port: port)
                }
            } catch {
                // Pipe closed — handled by the completion below.
            }

            await self?.readingEnded(port: port)
        }
    }

    private func consume(line: String, port: Int) {
        if urls[port] == nil, let url = Self.extractURL(from: line) {
            urls[port] = url
            waiters.removeValue(forKey: port)?.resume(returning: url)
            return
        }

        if line.localizedCaseInsensitiveContains("failed") || line.localizedCaseInsensitiveContains("error") {
            lastError[port] = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func readingEnded(port: Int) {
        guard let waiter = waiters.removeValue(forKey: port) else { return }
        waiter.resume(throwing: TunnelError.ended(lastError[port]))
    }

    private func scheduleTimeout(port: Int, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.timeOut(port: port)
        }
    }

    private func timeOut(port: Int) {
        guard let waiter = waiters.removeValue(forKey: port) else { return }
        waiter.resume(throwing: TunnelError.timedOut)
        stop(port: port)
    }
}
