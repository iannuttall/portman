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
        button.toolTip = "Port Manager"
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let count = store.badgeCount

        // isTemplate must be set on the image we actually hand to the button, and set
        // last: a symbol-configured copy comes back with isTemplate cleared. Without
        // it the symbol draws in its own colour — black — instead of following the
        // menu bar, which is white in dark mode.
        let symbol = NSImage(
            systemSymbolName: "rectangle.stack",
            accessibilityDescription: "Port Manager"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        )
        symbol?.isTemplate = true

        switch Preferences.menuBarMode {
        case .iconOnly:
            button.image = symbol
            button.title = ""
        case .iconAndCount:
            button.image = symbol
            button.imagePosition = .imageLeading
            button.title = String(count)
        case .countOnly:
            button.image = nil
            button.title = "\(count)"
        }

        // Left nil deliberately. Any explicit tint opts the button out of the
        // automatic menu-bar adaptation, so the icon stops following light/dark.
        button.contentTintColor = nil
    }

    /// `@Observable` doesn't emit notifications, so re-register after each read.
    private func observeBadge() {
        withObservationTracking {
            _ = store.badgeCount
            _ = store.hasIssues
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
        menu.addItem(withTitle: "Quit Port Manager", action: #selector(quit), keyEquivalent: "q")

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
