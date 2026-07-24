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
        let symbol = NSImage(
            systemSymbolName: "network",
            accessibilityDescription: "Port Manager"
        )
        symbol?.isTemplate = true

        switch Preferences.menuBarMode {
        case .iconOnly:
            button.image = symbol
            button.title = ""
        case .iconAndCount:
            button.image = symbol
            button.imagePosition = .imageLeading
            button.title = " \(count)"
        case .countOnly:
            button.image = nil
            button.title = "\(count)"
        }

        // A wedged or orphaned server is the one thing worth colouring for.
        button.contentTintColor = store.hasIssues ? .systemOrange : nil
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

        resizeToFit(panel)
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

        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hostingView = hosting

        return panel
    }

    /// The list grows and shrinks as servers come and go, so the panel is resized
    /// to its content every time it opens rather than pinned to a fixed height.
    private func resizeToFit(_ panel: NSPanel) {
        guard let hostingView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize

        let height = min(max(fitting.height, 120), Theme.Panel.maxHeight + 140)
        panel.setContentSize(NSSize(width: Theme.Panel.width, height: height))
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
        close()
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
        SettingsWindow.shared.show(store: store)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
