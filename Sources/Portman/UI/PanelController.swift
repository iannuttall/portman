import AppKit
import SwiftUI

/// A panel that can take keyboard focus without activating the app's windows.
///
/// This is why the app doesn't use `MenuBarExtra(.window)`: that scene style
/// can't reliably become key, which makes search-as-you-type and arrow-key
/// navigation impossible. A borderless `NSPanel` that overrides `canBecomeKey`
/// gives us a real first responder while still behaving like a menu.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the status item and the panel it drops down.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ServerStore
    private let statusItem: NSStatusItem
    private var panel: KeyablePanel?
    private var hostingView: NSHostingView<RootView>?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?

    /// Issues the status item has already blinked for. A problem earns one blink, not
    /// one per scan — the colour is what carries the state after that.
    private var flaggedIssues: Set<String> = []
    private var flashTask: Task<Void, Never>?

    var isOpen: Bool { panel?.isVisible == true }

    init(store: ServerStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        observeBadge()

        HotKeyCenter.shared.action = { [weak self] in
            self?.toggle()
        }
        HotKeyCenter.shared.apply()
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem()
    }

    /// Reconciles the whole status item — colour, count, tooltip — with the store.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        // Any in-flight blink is drawing to the same button, so it has to stop before
        // this writes the steady state or it would restore the state it captured.
        flashTask?.cancel()
        flashTask = nil

        let issues = store.issues
        render(alerting: !issues.isEmpty)
        button.toolTip = Self.tooltip(issues: issues, count: store.badgeCount)

        // A problem that was already showing doesn't blink again; only a new one does.
        // Without this the icon would blink on every scan for as long as the problem
        // lasted, which is how a signal turns into wallpaper.
        let current = Set(issues.map(\.id))
        let appeared = !current.subtracting(flaggedIssues).isEmpty
        flaggedIssues = current

        guard appeared, !store.reduceMotion else { return }
        startFlash()
    }

    /// Draws the status item in one of its two states.
    ///
    /// Split out from `updateStatusItem` because the blink is exactly this, alternated:
    /// the alerting look *is* the state, so flashing it off and on needs no second
    /// rendering path that could drift from the first.
    private func render(alerting: Bool) {
        guard let button = statusItem.button else { return }

        let count = String(store.badgeCount)

        switch Preferences.menuBarMode {
        case .iconOnly:
            button.image = Self.statusItemImage(alerting: alerting)
            button.attributedTitle = NSAttributedString(string: "")
        case .iconAndCount:
            button.image = Self.statusItemImage(alerting: alerting)
            button.imagePosition = .imageLeading
            button.attributedTitle = Self.title(count, on: button, tinted: false)
        case .countOnly:
            // No icon means nothing for the dot to sit on, so the number carries it.
            button.image = nil
            button.attributedTitle = Self.title(count, on: button, tinted: alerting)
        }

        // Left nil deliberately. Any explicit tint opts the button out of the
        // automatic menu-bar adaptation, so the icon stops following light/dark.
        // The dot is drawn into the image instead.
        button.contentTintColor = nil
    }

    /// The count.
    ///
    /// Set as an attributed title in *both* states rather than assigning `title` for the
    /// untinted one: the count often doesn't change when an alert clears, and a plain
    /// assignment of an unchanged string can leave the previous colour in place — the
    /// number would stay orange after the problem went away. `labelColor` is what the
    /// button would have used anyway, and it resolves against the menu bar's own
    /// appearance, so the untinted state still follows light and dark.
    private static func title(_ text: String, on button: NSButton, tinted: Bool) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: tinted ? Theme.Colour.menuBarAlert : NSColor.labelColor,
                .font: button.font ?? NSFont.menuBarFont(ofSize: 0)
            ]
        )
    }

    /// The plug, wearing a badge when something needs attention.
    ///
    /// A badge rather than an orange plug. The plug is the app's identity in a strip of
    /// twenty other icons, and recolouring the whole thing reads as an error state for
    /// Portman itself; a badge reads as "one of your servers". It also means the signal
    /// carries shape as well as colour, which a recolour alone doesn't.
    private static func statusItemImage(alerting: Bool) -> NSImage? {
        guard let symbol = plugSymbol() else { return nil }
        guard alerting else {
            // isTemplate must be set on the image we actually hand to the button, and
            // set last: a symbol-configured copy comes back with the flag cleared.
            // Without it the symbol draws in its own colour — black — instead of
            // following the menu bar, which is white in dark mode.
            symbol.isTemplate = true
            return symbol
        }

        return badged(symbol)
    }

    /// A plug, matching the app icon.
    ///
    /// The portrait variant is the narrowest of the plug symbols, which matters — the
    /// menu bar runs out of room and macOS silently hides whatever no longer fits.
    /// Filled rather than outline: at 16px an outline plug reads as a smudge.
    private static func plugSymbol() -> NSImage? {
        let names = ["powerplug.portrait.fill", "powerplug.fill", "powerplug", "rectangle.stack"]

        for name in names {
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.displayName) else {
                continue
            }

            return base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            ) ?? base
        }

        return nil
    }

    /// Composites the alert dot over the plug's bottom-right corner.
    ///
    /// The badged image can't be a template — a template is tinted wholesale to the menu
    /// bar's colour, which would turn the badge black. So the plug's own colour has to be
    /// stated here, and the drawing is deferred rather than composited once: the handler
    /// runs inside the button's appearance, so `labelColor` resolves to white on a dark
    /// menu bar and black on a light one. Painting it at build time would freeze whichever
    /// appearance happened to be current when the scan finished.
    private static func badged(_ symbol: NSImage) -> NSImage {
        let diameter = Theme.Size.menuBarBadge
        let moat = Theme.Size.menuBarBadgeMoat
        let overhang = Theme.Size.menuBarBadgeOverhang

        // The badge hangs off the right edge rather than being given a column of its own,
        // so a problem costs a couple of points of menu bar instead of a whole slot.
        let size = NSSize(width: symbol.size.width + overhang + moat, height: symbol.size.height)
        let badge = NSRect(x: size.width - diameter - moat, y: 0, width: diameter, height: diameter)

        let image = NSImage(size: size, flipped: false) { _ in
            let plug = NSRect(origin: .zero, size: symbol.size)
            symbol.draw(in: plug)

            // Template images arrive black; `.sourceAtop` recolours the glyph in place
            // without painting the transparent area around it.
            NSColor.labelColor.set()
            plug.fill(using: .sourceAtop)

            // Punch a transparent ring out of the plug before laying the badge in it.
            // Without the gap the badge merges into the plug's filled body and the pair
            // reads as one indistinct blob at 16px.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -moat, dy: -moat)).fill()
            NSGraphicsContext.restoreGraphicsState()

            Theme.Colour.menuBarAlert.setFill()
            NSBezierPath(ovalIn: badge).fill()
            return true
        }

        image.isTemplate = false
        return image
    }

    /// Blinks the alert off and on a few times, once, when a problem first appears.
    ///
    /// Discrete rather than a repeating pulse. A menu bar icon that pulses forever is
    /// noise you stop seeing within a day, and it would still be pulsing long after you
    /// had read it — the colour holds the state, and this only says "look now".
    private func startFlash() {
        flashTask = Task { @MainActor [weak self] in
            for beat in 0..<Theme.Motion.menuBarFlashBeats {
                self?.render(alerting: false)
                try? await Task.sleep(for: Theme.Motion.menuBarFlashOff)
                guard !Task.isCancelled else { break }

                self?.render(alerting: true)

                // No trailing pause on the last beat — it's already in its final state.
                guard beat < Theme.Motion.menuBarFlashBeats - 1 else { break }
                try? await Task.sleep(for: Theme.Motion.menuBarFlashOn)
                guard !Task.isCancelled else { break }
            }

            // Cancellation means someone else is mid-render; leave the button to them.
            guard !Task.isCancelled else { return }
            self?.render(alerting: true)
            self?.flashTask = nil
        }
    }

    /// The status item's only room for detail, so it names what's wrong rather than
    /// counting it. "Port 3000 has more than one listener" is something you can act on;
    /// "1 issue" only tells you to go and open the panel.
    private static func tooltip(issues: [ServerIssue], count: Int) -> String {
        let listening = "\(count) listening"

        guard !issues.isEmpty else {
            return "\(AppInfo.displayName) — \(listening)"
        }

        let heading = "\(AppInfo.displayName) — \(listening), \(issues.count) needing attention"

        // A tooltip taller than the menu bar's neighbourhood is worse than one that
        // admits what it left out.
        let shown = issues.prefix(5).map(\.sentence)
        let hidden = issues.count - shown.count
        let lines = hidden > 0 ? shown + ["…and \(hidden) more"] : Array(shown)

        return ([heading] + lines).joined(separator: "\n")
    }

    /// `@Observable` doesn't emit notifications, so re-register after each read.
    ///
    /// The whole `issues` list is tracked rather than a "has issues" boolean: one problem
    /// clearing as another appears leaves a boolean untouched, and the tooltip would keep
    /// naming the issue that had already gone.
    private func observeBadge() {
        withObservationTracking {
            _ = store.badgeCount
            _ = store.issues
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
                self?.observeBadge()
            }
        }
    }

    // MARK: - Toggle

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        toggle()
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        let panel = panel ?? makePanel()
        self.panel = panel

        sizeOnOpen(panel)
        position(panel)
        store.panelDidOpen()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        startMonitoring()
    }

    func close() {
        stopMonitoring()
        panel?.orderOut(nil)
        store.panelDidClose()
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Panel.width, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let root = RootView(store: store) { [weak self] in
            self?.close()
        }

        // Deliberately NOT .intrinsicContentSize. Letting the content drive the
        // window meant the panel resized whenever the list changed — and because
        // NSWindow origins are bottom-left, every resize walked it away from the
        // menu bar. The controller owns the size now; content scrolls inside it.
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        hostingView = hosting

        return panel
    }

    /// Chooses the panel height once, when it opens, and then leaves it alone.
    ///
    /// The height is estimated from the row count rather than measured, because
    /// measuring means letting the content drive the window — which is what made the
    /// panel jump. The floor is deliberately tall enough to show an expanded row
    /// including its preview, so expanding never leaves the card clipped.
    private func sizeOnOpen(_ panel: NSPanel) {
        let rows = store.rows.count
        let sectionHeaders = store.sections.filter { $0.title != nil }.count

        let rowHeight: CGFloat = store.rowDensity == .detailed ? 52 : 44
        let content = CGFloat(rows) * rowHeight + CGFloat(sectionHeaders) * 30
        let estimated = Theme.Panel.chrome + content

        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? Theme.Panel.maxHeight
        let ceiling = min(Theme.Panel.maxHeight, available - 40)
        let height = min(max(estimated, Theme.Panel.minHeight), ceiling)

        panel.setContentSize(NSSize(width: Theme.Panel.width, height: height))
    }

    /// Keeps the top edge under the status item, whatever the current height is.
    private func pinTop(of panel: NSPanel) {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else {
            return
        }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let size = panel.frame.size

        var origin = NSPoint(
            x: panel.frame.origin.x,
            y: buttonRect.minY - size.height - Theme.Panel.menuBarGap
        )

        origin.y = max(origin.y, visible.minY + 8)

        guard abs(origin.y - panel.frame.origin.y) > 0.5 else { return }
        panel.setFrameOrigin(origin)
    }

    /// Drops the panel under the status item, nudged back on screen if the item
    /// sits near the right edge.
    private func position(_ panel: NSPanel) {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else {
            return
        }

        panel.layoutIfNeeded()

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let visible = screen.visibleFrame

        var origin = NSPoint(
            x: buttonRect.midX - size.width / 2,
            y: buttonRect.minY - size.height - Theme.Panel.menuBarGap
        )

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)

        panel.setFrameOrigin(origin)
    }

    // MARK: - Dismissal

    private func startMonitoring() {
        stopMonitoring()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }

        // Navigation keys are routed here rather than through SwiftUI because the
        // search field holds focus the whole time the panel is open, and its field
        // editor would otherwise eat the arrows and Return.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event) ? nil : event
        }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case 53: // esc — back out one level at a time
            if store.expandedRowID != nil {
                store.expandedRowID = nil
            } else if !store.searchText.isEmpty {
                store.searchText = ""
            } else {
                close()
            }
            return true

        case 125: // down
            store.moveSelection(by: 1)
            return true

        case 126: // up
            store.moveSelection(by: -1)
            return true

        case 124: // right — expand
            if let id = store.selectedRowID, store.expandedRowID != id {
                store.toggleExpanded(id)
                return true
            }
            return false

        case 123: // left — collapse
            if store.expandedRowID != nil {
                store.expandedRowID = nil
                return true
            }
            return false

        case 36: // return
            guard let row = store.selectedRow ?? store.rows.first else { return false }

            if command, let path = row.entry.path {
                AppLauncher.openInEditor(path: path, bundleID: Preferences.editorBundleID)
            } else {
                store.open(row.entry)
            }

            close()
            return true

        case 51 where command: // ⌘⌫ — kill
            guard let row = store.selectedRow else { return false }
            store.kill(row)
            return true

        case 8 where command: // ⌘C — copy the URL, not the selected text
            guard let row = store.selectedRow else { return false }
            store.copy(store.url(for: row.entry).absoluteString)
            return true

        default:
            return false
        }
    }

    private func stopMonitoring() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }

        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Menus opened from inside the panel (the sort/group menu, a context menu)
        // take key while the panel is still meant to be up. Only the outside-click
        // monitor and Esc dismiss it.
    }

    /// Re-pins the top edge whenever the content height changes.
    ///
    /// `NSWindow` origins are bottom-left, so a panel that grows — expanding a row,
    /// showing the confirmation bar — pushes its own top edge upward and walks away
    /// from the menu bar. Anchoring the top on every resize keeps it put.
    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        pinTop(of: panel)
    }

    // MARK: - Right-click menu

    private func showContextMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppInfo.displayName)", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() {
        store.refresh(force: true)
    }

    @objc private func openSettings() {
        close()
        SettingsWindow.shared.show(store: store)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
