import AppKit
import Foundation
import ServiceManagement

@MainActor
final class PortManagerApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var currentProcesses: [ListeningProcess] = []
    var isRefreshing = false
    var lastRefresh: Date?
    var networkAddress: String?
    var settingsWindow: NSWindow?
    var ignoredPortsTextView: NSTextView?
    var ignoredCommandsTextView: NSTextView?
    var ignoredTargetsTextView: NSTextView?

    var showAllProcesses: Bool {
        get {
            UserDefaults.standard.bool(forKey: "showAllProcesses")
        }

        set {
            UserDefaults.standard.set(newValue, forKey: "showAllProcesses")
        }
    }

    var pinnedKeys: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "pinnedKeys") ?? [])
        }

        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "pinnedKeys")
        }
    }

    var ignoredPorts: Set<Int> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "ignoredPorts")?.compactMap(Int.init) ?? [])
        }

        set {
            UserDefaults.standard.set(newValue.map(String.init).sorted(), forKey: "ignoredPorts")
        }
    }

    var ignoredCommands: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "ignoredCommands") ?? [])
        }

        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "ignoredCommands")
        }
    }

    var ignoredTargets: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "ignoredTargets") ?? [])
        }

        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "ignoredTargets")
        }
    }

    var visibleProcesses: [ListeningProcess] {
        let processes = currentProcesses.filter { !isIgnored($0) }

        if showAllProcesses {
            return processes
        }

        return processes.filter { !$0.hiddenByDefault }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        rebuildMenu()
        requestRefresh(force: true)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Port Manager")
        button.imagePosition = .imageRight
        button.title = "0"
        button.toolTip = "Port Manager"
    }

    private func configureMenu() {
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        requestRefresh()
    }

    func requestRefresh(force: Bool = false) {
        if isRefreshing {
            return
        }

        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 5 {
            return
        }

        isRefreshing = true

        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                (
                    processes: PortScanner().listeningProcesses(),
                    networkAddress: PortManagerApp.localIPAddressValue()
                )
            }.value

            guard let self else { return }

            currentProcesses = snapshot.processes
            networkAddress = snapshot.networkAddress
            lastRefresh = Date()
            isRefreshing = false
            rebuildMenu()
        }
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let processes = visibleProcesses

        let heading = NSMenuItem(title: "Listening Processes", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if processes.isEmpty {
            let title = isRefreshing ? "Scanning..." : "No listening ports found"
            let empty = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            addConflictItems(for: processes, to: menu)
            addProcessItems(processes, to: menu)
        }

        menu.addItem(.separator())

        let preferences = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferences.isEnabled = false
        menu.addItem(preferences)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let loginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleOpenAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = openAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        let showAllItem = NSMenuItem(
            title: "Show System Ports",
            action: #selector(toggleShowAllProcesses(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = self
        showAllItem.state = showAllProcesses ? .on : .off
        menu.addItem(showAllItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let aboutItem = NSMenuItem(title: "About Port Manager", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem.button {
            button.title = "\(processes.count)"
        }
    }
}
