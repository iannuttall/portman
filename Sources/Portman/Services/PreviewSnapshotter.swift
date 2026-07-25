import AppKit
import Foundation
import WebKit

/// Renders a thumbnail of what a dev server is actually serving.
///
/// Strictly on demand: this only ever runs for the one row the user expanded, one render
/// at a time, and never as a prefetch. Rendering a page is expensive and a dev server is
/// somebody's live app — hitting every port on every scan would be rude and slow.
///
/// Every failure path returns `nil`. A port that isn't HTTP, a page that errors, WebKit
/// refusing to start outside an app bundle — none of that is worth an alert.
@MainActor
final class PreviewSnapshotter {
    static let shared = PreviewSnapshotter()

    /// Logical size we render at: wide enough that a desktop layout doesn't collapse to
    /// its mobile breakpoint, short enough to stay cheap.
    private static let renderSize = CGSize(width: 1000, height: 700)

    /// Panel width less both gutters — the width of an expanded row's card.
    private static let thumbnailWidth = Theme.Panel.width - (Theme.Space.gutter * 2)

    /// A page that hasn't finished in this long is not going to.
    private static let loadTimeout: TimeInterval = 4

    /// Long enough that a returning user sees something instantly, short enough that it
    /// still resembles the running server.
    private static let maxAge: TimeInterval = 3600

    private struct Entry {
        let image: NSImage
        let capturedAt: Date
    }

    private var memory: [Int: Entry] = [:]

    /// One render at a time, and one render per port: concurrent callers for the same
    /// port await the same task instead of opening a second web view.
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]
    private var gate: Task<Void, Never> = Task {}

    private let directory: URL

    private init() {
        directory = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(
            .cachesDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(AppInfo.cacheNamespace)/previews", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Entry points

    /// Returns a cached thumbnail immediately if it is fresh, otherwise renders one.
    func snapshot(port: Int, force: Bool = false) async -> NSImage? {
        if !force, let cached = cachedSnapshot(port: port) { return cached }
        if let existing = inFlight[port] { return await existing.value }

        let previous = gate
        let task = Task<NSImage?, Never> { [weak self] in
            await previous.value
            guard let self else { return nil }

            let image = await self.render(port: port)
            if let image { self.store(image, port: port) }
            self.inFlight[port] = nil

            return image
        }

        inFlight[port] = task
        gate = Task { _ = await task.value }

        return await task.value
    }

    func cachedSnapshot(port: Int) -> NSImage? {
        if let entry = memory[port] {
            return Date().timeIntervalSince(entry.capturedAt) < Self.maxAge ? entry.image : nil
        }

        guard let entry = readFromDisk(port: port) else { return nil }
        memory[port] = entry

        return Date().timeIntervalSince(entry.capturedAt) < Self.maxAge ? entry.image : nil
    }

    /// When the thumbnail was taken, so a row can mark a stale preview as such.
    func capturedAt(port: Int) -> Date? {
        if let entry = memory[port] { return entry.capturedAt }
        return readFromDisk(port: port)?.capturedAt
    }

    func invalidate(port: Int) {
        memory.removeValue(forKey: port)
        try? FileManager.default.removeItem(at: url(for: port))
    }

    // MARK: - Rendering

    private func render(port: Int) async -> NSImage? {
        // WebKit needs a real bundle to start its helper processes. Under `swift run`
        // there isn't one, and asking anyway takes down the process.
        guard Bundle.main.bundleIdentifier != nil else { return nil }

        // Same split as `HealthProbe`: a server that bound `localhost` may only be
        // listening on `::1`, and nothing at all answers on 127.0.0.1.
        if let image = await render(port: port, host: "127.0.0.1") { return image }
        return await render(port: port, host: "[::1]")
    }

    private func render(port: Int, host: String) async -> NSImage? {
        guard let url = URL(string: "http://\(host):\(port)/") else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true

        let frame = CGRect(origin: .zero, size: Self.renderSize)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        // A detached web view never paints, so it needs a window — parked well off any
        // screen so nothing ever flashes in front of the user.
        let window = NSWindow(
            contentRect: CGRect(x: -30_000, y: -30_000, width: frame.width, height: frame.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = webView
        window.orderBack(nil)

        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
            window.contentView = nil
            window.close()
        }

        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.loadTimeout
        ))

        guard await waiter.finished(within: Self.loadTimeout) else { return nil }

        // One frame's grace so the first paint lands before the snapshot.
        try? await Task.sleep(for: .milliseconds(150))

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: Self.renderSize)
        snapshotConfiguration.afterScreenUpdates = true

        guard let full = try? await webView.takeSnapshot(configuration: snapshotConfiguration) else {
            return nil
        }

        return Self.thumbnail(from: full)
    }

    /// Scales to the card width and keeps the top of the page — the part with the header,
    /// which is what makes a preview recognisable at this size.
    private static func thumbnail(from source: NSImage) -> NSImage? {
        let target = CGSize(width: thumbnailWidth, height: Theme.Size.thumbnailHeight)
        guard source.size.width > 0, source.size.height > 0 else { return nil }

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width * 2),
            pixelsHigh: Int(target.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        representation.size = target

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }

        let scaled = CGSize(
            width: target.width,
            height: (source.size.height / source.size.width) * target.width
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: CGRect(
                x: 0,
                y: target.height - scaled.height,
                width: scaled.width,
                height: scaled.height
            ),
            from: CGRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: target)
        image.addRepresentation(representation)

        return image
    }

    // MARK: - Cache

    private func store(_ image: NSImage, port: Int) {
        memory[port] = Entry(image: image, capturedAt: Date())

        guard let representation = image.representations.first as? NSBitmapImageRep,
              let data = representation.representation(using: .png, properties: [:]) else {
            return
        }

        try? data.write(to: url(for: port), options: .atomic)
    }

    private func readFromDisk(port: Int) -> Entry? {
        let location = url(for: port)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: location.path),
              let modified = attributes[.modificationDate] as? Date,
              let image = NSImage(contentsOf: location) else {
            return nil
        }

        return Entry(image: image, capturedAt: modified)
    }

    private func url(for port: Int) -> URL {
        directory.appendingPathComponent("\(port).png")
    }
}

// MARK: - Navigation

/// Resolves once, whichever comes first: the page finished, the page failed, or we ran
/// out of patience. A partially rendered page still makes a useful thumbnail, so a
/// timeout is not treated as a failure.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var settled = false

    func finished(within timeout: TimeInterval) async -> Bool {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.settle(false)
        }

        defer { watchdog.cancel() }

        return await withCheckedContinuation { continuation in
            if settled {
                continuation.resume(returning: false)
                return
            }

            self.continuation = continuation
        }
    }

    private func settle(_ loaded: Bool) {
        guard !settled else { return }
        settled = true

        let pending = continuation
        continuation = nil
        pending?.resume(returning: loaded)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(true)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        // The DOM is up even though a subresource failed; snapshot what we have.
        settle(true)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        settle(false)
    }

    /// Same loopback rule as `HealthProbe`: dev servers sign their own certificates.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
