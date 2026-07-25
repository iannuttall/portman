import Darwin
import Foundation

/// Asks every listening port what it actually is.
///
/// The interesting answer is not "is it up" — `lsof` already told us a process holds
/// the port. The interesting answer is *hung*: the socket accepts a connection and then
/// nothing ever comes back. A wedged Vite or Next dev server looks identical to a healthy
/// one from the outside, so we make the distinction explicit:
///
/// - a reply that parses as HTTP, whatever the status code, is `.healthy`
/// - a reply that isn't HTTP is `.nonHTTP` (Postgres, Redis, raw TCP)
/// - a connection that opens and stays silent is `.hung`
/// - a refused connection means the process died between the scan and the probe
///
/// `URLSession` collapses most of those into one opaque `URLError`, so a failed request
/// is followed by a raw-socket exchange that looks at the bytes on the wire.
actor HealthProbe {
    /// How long a report stays good enough to hand back without re-probing.
    private let ttl: TimeInterval

    /// Probes in flight at once. Enough to keep a full port list quick, low enough that
    /// a machine full of hung servers doesn't open thirty sockets at a time.
    private static let maxInFlight = 8

    /// We only ever need the `<head>`; the cap stops a streaming endpoint from
    /// holding a probe open for the whole resource timeout.
    private static let maxBodyBytes = 64 * 1024

    private struct CacheEntry {
        let report: HealthReport
        let storedAt: Date
    }

    private var cache: [Int: CacheEntry] = [:]

    init(ttl: TimeInterval = 10) {
        self.ttl = ttl
    }

    // MARK: - Entry points

    /// Probes many ports concurrently. Never throws; a failure is a `HealthReport` state.
    func probe(ports: [Int], timeout: TimeInterval = 1.5) async -> [Int: HealthReport] {
        let now = Date()
        var results: [Int: HealthReport] = [:]
        var pending: [Int] = []

        for port in Set(ports) {
            if let cached = cache[port], now.timeIntervalSince(cached.storedAt) < ttl {
                results[port] = cached.report
            } else {
                pending.append(port)
            }
        }

        guard !pending.isEmpty else { return results }
        pending.sort()

        let context = Context(timeout: timeout)
        defer { context.invalidate() }

        let probed = await withTaskGroup(of: (Int, HealthReport).self) { group in
            var iterator = pending.makeIterator()
            var started = 0

            while started < Self.maxInFlight, let port = iterator.next() {
                group.addTask { (port, await Self.probe(port: port, context: context)) }
                started += 1
            }

            var collected: [Int: HealthReport] = [:]

            while let (port, report) = await group.next() {
                collected[port] = report

                if let next = iterator.next() {
                    group.addTask { (next, await Self.probe(port: next, context: context)) }
                }
            }

            return collected
        }

        let storedAt = Date()

        for (port, report) in probed {
            cache[port] = CacheEntry(report: report, storedAt: storedAt)
            results[port] = report
        }

        return results
    }

    /// Drops the cached report for one port so the next probe hits the wire.
    /// Call this after a restart or a kill.
    func invalidate(port: Int) {
        cache.removeValue(forKey: port)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - One port

    private static func probe(port: Int, context: Context) async -> HealthReport {
        let report = await probe(port: port, loopback: .v4, context: context)
        guard report.state == .refused else { return report }

        // Vite, Astro and Next bind `localhost`, which on this machine resolves to `::1`
        // only. Nothing answers on 127.0.0.1 and the server is very much alive, so a
        // refusal is never the final answer until IPv6 has refused too.
        let overIPv6 = await probe(port: port, loopback: .v6, context: context)
        return overIPv6.state == .refused ? report : overIPv6
    }

    private static func probe(
        port: Int,
        loopback: Loopback,
        context: Context
    ) async -> HealthReport {
        if let fetched = try? await fetch(
            port: port,
            scheme: "http",
            loopback: loopback,
            session: context.plain,
            context: context
        ) {
            return report(from: fetched, scheme: "http")
        }

        // `URLSession` failed. Everything below decides *why* by looking at the wire.
        let timeout = min(context.timeout, 0.75)

        switch await SocketExchange.run(port: port, loopback: loopback, timeout: timeout) {
        case .refused:
            return finished(HealthReport(state: .refused))

        case .silent:
            return finished(HealthReport(state: .hung))

        case .closed:
            // Hung up without a byte. A TLS server that got plaintext often does exactly
            // this, so it is worth one HTTPS attempt before calling it non-HTTP.
            return await secureAttempt(port: port, loopback: loopback, context: context)
                ?? finished(HealthReport(state: .nonHTTP))

        case .reply(let data, let latency):
            if SocketExchange.looksLikeHTTP(data) {
                // It speaks HTTP even though `URLSession` gave up — a malformed header or
                // an encoding it wouldn't take. Report what the status line says.
                var report = HealthReport(state: .healthy)
                report.statusCode = SocketExchange.statusCode(from: data)
                report.latency = latency
                report.serverHeader = SocketExchange.serverHeader(from: data)
                return finished(report)
            }

            if SocketExchange.looksLikeTLS(data) {
                return await secureAttempt(port: port, loopback: loopback, context: context)
                    ?? finished(HealthReport(state: .nonHTTP))
            }

            return finished(HealthReport(state: .nonHTTP))
        }
    }

    private static func secureAttempt(
        port: Int,
        loopback: Loopback,
        context: Context
    ) async -> HealthReport? {
        guard let fetched = try? await fetch(
            port: port,
            scheme: "https",
            loopback: loopback,
            session: context.insecure,
            context: context
        ) else {
            return nil
        }

        return report(from: fetched, scheme: "https")
    }

    private static func report(from fetched: Fetched, scheme: String) -> HealthReport {
        var report = HealthReport(state: .healthy)
        report.statusCode = fetched.statusCode
        report.latency = fetched.latency
        report.pageTitle = fetched.title
        report.serverHeader = fetched.serverHeader
        report.scheme = scheme
        return finished(report)
    }

    private static func finished(_ report: HealthReport) -> HealthReport {
        var stamped = report
        stamped.checkedAt = Date()
        return stamped
    }

    // MARK: - HTTP

    private struct Fetched: Sendable {
        let statusCode: Int
        let latency: TimeInterval
        let serverHeader: String?
        let title: String?
    }

    /// GET, never HEAD — plenty of dev servers mishandle HEAD, and the body is where
    /// the page title lives. Latency is measured to the response head, not the last byte.
    private static func fetch(
        port: Int,
        scheme: String,
        loopback: Loopback,
        session: URLSession,
        context: Context
    ) async throws -> Fetched {
        guard let url = URL(string: "\(scheme)://\(loopback.urlHost):\(port)/") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: context.timeout
        )
        request.httpMethod = "GET"
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let clock = ContinuousClock()
        let started = clock.now
        let (bytes, response) = try await session.bytes(for: request)
        let latency = seconds(clock.now - started)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        return Fetched(
            statusCode: http.statusCode,
            latency: latency,
            serverHeader: http.value(forHTTPHeaderField: "Server"),
            title: await head(of: bytes)
        )
    }

    /// Reads just enough of the body to find a title, then walks away.
    private static func head(of bytes: URLSession.AsyncBytes) async -> String? {
        var body = Data()
        body.reserveCapacity(4096)

        do {
            for try await byte in bytes {
                body.append(byte)

                if reachedTitleEnd(body) { break }
                if body.count >= maxBodyBytes { break }
            }
        } catch {
            // A truncated body is still worth reading — the title is usually already in it.
        }

        guard !body.isEmpty else { return nil }
        return extractTitle(from: String(decoding: body, as: UTF8.self))
    }

    /// Cheap tail check so we stop at `</title>` instead of scanning the whole buffer
    /// after every byte. `| 0x20` lowercases ASCII letters and leaves `<`, `/` and `>` alone.
    private static func reachedTitleEnd(_ body: Data) -> Bool {
        guard body.count >= 8 else { return false }
        return body.suffix(8).map { $0 | 0x20 } == Array("</title>".utf8)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    // MARK: - Title

    /// Pulls the `<title>` out of a page: tolerates attributes on the tag, a title split
    /// over several lines, and the handful of entities that show up in real page titles.
    static func extractTitle(from html: String) -> String? {
        guard let raw = titleContents(of: html) else { return nil }

        let collapsed = decodeEntities(raw)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return collapsed.isEmpty ? nil : collapsed
    }

    private static func titleContents(of html: String) -> String? {
        var searchStart = html.startIndex

        while let opening = html.range(
            of: "<title",
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            searchStart = opening.upperBound
            let afterName = html[opening.upperBound...]

            // Guards against `<titlebar>` and friends.
            guard let boundary = afterName.first,
                  boundary == ">" || boundary == "/" || boundary.isWhitespace else {
                continue
            }

            guard let tagEnd = afterName.firstIndex(of: ">") else { return nil }
            searchStart = afterName.index(after: tagEnd)

            // `<title/>` opens nothing; whatever `</title>` comes next belongs to some
            // other element, usually an inline SVG.
            if tagEnd > afterName.startIndex,
               afterName[afterName.index(before: tagEnd)] == "/" {
                continue
            }

            let body = afterName[searchStart...]
            guard let closing = body.range(of: "</title", options: .caseInsensitive) else {
                return nil
            }

            return String(body[..<closing.lowerBound])
        }

        return nil
    }

    /// Single pass, so `&amp;lt;` decodes to `&lt;` rather than `<`.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while let ampersand = text[index...].firstIndex(of: "&") {
            result.append(contentsOf: text[index..<ampersand])

            // A stray `&` in prose is common; only look ahead a plausible entity length.
            guard let semicolon = text[ampersand...].firstIndex(of: ";"),
                  text.distance(from: ampersand, to: semicolon) <= 10 else {
                result.append("&")
                index = text.index(after: ampersand)
                continue
            }

            let entity = text[text.index(after: ampersand)..<semicolon]

            if let replacement = replacement(for: entity) {
                result.append(replacement)
            } else {
                result.append(contentsOf: text[ampersand...semicolon])
            }

            index = text.index(after: semicolon)
        }

        result.append(contentsOf: text[index...])
        return result
    }

    private static func replacement(for entity: Substring) -> String? {
        if let named = namedEntities[entity.lowercased()] { return named }
        guard entity.hasPrefix("#") else { return nil }

        let digits = entity.dropFirst()
        let value: UInt32?

        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }

        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": " ",
        "mdash": "—",
        "ndash": "–",
        "hellip": "…"
    ]
}

// MARK: - Loopback

/// Which loopback address to knock on. Both matter: plenty of dev servers bind `::1`
/// only, and plenty of databases bind `127.0.0.1` only.
private enum Loopback: Sendable {
    case v4
    case v6

    /// Already bracketed for IPv6 so it can be dropped straight into a URL or a `Host:`.
    var urlHost: String {
        switch self {
        case .v4: return "127.0.0.1"
        case .v6: return "[::1]"
        }
    }

    var family: Int32 {
        switch self {
        case .v4: return AF_INET
        case .v6: return AF_INET6
        }
    }
}

// MARK: - Session context

/// The two sessions one probe pass shares. `URLSession` is thread-safe, so handing the
/// same pair to every child task is fine; the box is only here to say so to the compiler.
private struct Context: @unchecked Sendable {
    let plain: URLSession
    let insecure: URLSession
    let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
        plain = Context.session(timeout: timeout, delegate: LoopbackTrustDelegate())
        insecure = Context.session(timeout: timeout, delegate: LoopbackTrustDelegate())
    }

    func invalidate() {
        plain.finishTasksAndInvalidate()
        insecure.finishTasksAndInvalidate()
    }

    private static func session(
        timeout: TimeInterval,
        delegate: (any URLSessionDelegate)?
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2

        guard let delegate else {
            return URLSession(configuration: configuration)
        }

        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

/// Accepts whatever certificate loopback presents. Dev servers sign their own, and this
/// session is only ever pointed at loopback — it never carries a request off the machine.
///
/// This has to be the *task*-level challenge method: `URLSession.bytes(for:)` installs its
/// own bridge as the task delegate, and a session-level `didReceive` is never consulted.
private final class LoopbackTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let allowedHosts: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.allowedHosts.contains(challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// Refuses to follow a redirect that leaves the machine.
    ///
    /// A dev server that 302s to a staging or production host would otherwise have us
    /// fetching it — an off-box request the user never asked for, on a timer, for every
    /// port they happen to be running. Redirects that stay on loopback are followed
    /// normally; anything else stops and the redirect response itself is the answer,
    /// which is all the health check needs.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host, Self.allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }
}

// MARK: - Raw socket

/// A deliberately dumb HTTP request over a bare socket, used when `URLSession` fails and
/// we need to know whether the port refused us, went quiet, or answered in another protocol.
private enum SocketExchange {
    enum Outcome: Sendable {
        /// Nothing is listening any more.
        case refused
        /// Connected and sent the request; the peer sent these bytes back.
        case reply(Data, latency: TimeInterval)
        /// Connected, then the peer hung up without answering.
        case closed
        /// Connected and the peer never said anything.
        case silent
    }

    private static let queue = DispatchQueue(
        label: "\(AppInfo.bundleID).health-socket",
        attributes: .concurrent
    )

    /// Hops onto a dispatch queue: the implementation blocks on `poll`, and blocking a
    /// cooperative thread for the length of a timeout would stall unrelated work.
    static func run(port: Int, loopback: Loopback, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: exchange(port: port, loopback: loopback, timeout: timeout)
                )
            }
        }
    }

    static func looksLikeHTTP(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual(Array("HTTP/".utf8))
    }

    /// A TLS server handed a plaintext request answers with a record header: content type
    /// 0x15 (alert) or 0x16 (handshake), then the 0x03 major version.
    static func looksLikeTLS(_ data: Data) -> Bool {
        let prefix = Array(data.prefix(2))
        guard prefix.count == 2 else { return false }
        return (prefix[0] == 0x15 || prefix[0] == 0x16) && prefix[1] == 0x03
    }

    static func statusCode(from data: Data) -> Int? {
        let line = String(decoding: data.prefix(64), as: UTF8.self)
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return Int(fields[1])
    }

    static func serverHeader(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("server:") {
            let value = line.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        return nil
    }

    // MARK: Blocking implementation, always run on `queue`

    private static func exchange(port: Int, loopback: Loopback, timeout: TimeInterval) -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = Date().addingTimeInterval(timeout)
        let descriptor = socket(loopback.family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .refused }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return .refused
        }

        var enabled: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )

        switch connect(descriptor: descriptor, port: port, loopback: loopback, deadline: deadline) {
        case .refused: return .refused
        case .silent: return .silent
        case .connected: break
        }

        let request = "GET / HTTP/1.1\r\n"
            + "Host: \(loopback.urlHost):\(port)\r\n"
            + "User-Agent: \(AppInfo.userAgent)\r\n"
            + "Accept: */*\r\n"
            + "Connection: close\r\n\r\n"

        let sent = Array(request.utf8).withUnsafeBytes { buffer in
            send(descriptor, buffer.baseAddress, buffer.count, 0)
        }

        guard sent > 0 else { return .closed }
        guard wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline) else {
            return .silent
        }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(descriptor, &buffer, buffer.count, 0)

        if received > 0 {
            return .reply(Data(buffer.prefix(received)), latency: seconds(clock.now - started))
        }

        if received == 0 { return .closed }
        return errno == ECONNRESET ? .closed : .silent
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private enum ConnectResult {
        case connected
        case refused
        /// The listen backlog swallowed us: the process is up but never calls `accept`.
        case silent
    }

    private static func connect(
        descriptor: Int32,
        port: Int,
        loopback: Loopback,
        deadline: Date
    ) -> ConnectResult {
        let result: Int32

        switch loopback {
        case .v4:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

        case .v6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(truncatingIfNeeded: port).bigEndian
            address.sin6_addr = in6addr_loopback

            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }

        if result == 0 { return .connected }
        guard errno == EINPROGRESS else { return .refused }
        guard wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline) else {
            return .silent
        }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return .refused
        }

        return socketError == 0 ? .connected : .refused
    }

    private static func wait(descriptor: Int32, events: Int16, deadline: Date) -> Bool {
        var entry = pollfd(fd: descriptor, events: events, revents: 0)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }

            let result = poll(&entry, 1, Int32(remaining * 1000))
            if result > 0 { return true }
            if result == 0 { return false }
            guard errno == EINTR else { return false }
        }
    }
}
