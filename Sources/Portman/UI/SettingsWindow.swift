import AppKit
import ServiceManagement
import SwiftUI

/// A real settings window, replacing the three raw text views the old build used
/// for ignore rules.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    /// Brings the settings window up in front of everything.
    ///
    /// The panel runs at `.popUpMenu` level, which is above any ordinary window, so
    /// callers must close the panel first — otherwise this opens behind it and looks
    /// like nothing happened. `orderFrontRegardless` covers the accessory-app case
    /// where activation alone doesn't reliably front a window.
    func show(store: ServerStore) {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppInfo.displayName) Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 520))
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @Bindable var store: ServerStore

    var body: some View {
        TabView {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }

            DisplaySettings(store: store)
                .tabItem { Label("Display", systemImage: "slider.horizontal.3") }

            AppsSettings()
                .tabItem { Label("Apps", systemImage: "app.badge") }

            IgnoreSettings(store: store)
                .tabItem { Label("Ignore Rules", systemImage: "eye.slash") }
        }
        .frame(width: 480, height: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var store: ServerStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var refreshInterval = Preferences.refreshInterval
    @State private var menuBarMode = Preferences.menuBarMode
    @State private var hotKeyEnabled = Preferences.hotKeyEnabled
    @State private var hotKey = Preferences.hotKey

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Menu bar", selection: $menuBarMode) {
                    ForEach(MenuBarMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: menuBarMode) { _, newValue in
                    Preferences.menuBarMode = newValue
                }

                Toggle("Show system ports", isOn: $store.showAllProcesses)
            }

            Section("Shortcut") {
                Toggle("Global shortcut", isOn: $hotKeyEnabled)
                    .onChange(of: hotKeyEnabled) { _, newValue in
                        Preferences.hotKeyEnabled = newValue
                        HotKeyCenter.shared.apply()
                    }

                Picker("Opens the panel", selection: $hotKey) {
                    ForEach(HotKeyChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .disabled(!hotKeyEnabled)
                .onChange(of: hotKey) { _, newValue in
                    Preferences.hotKey = newValue
                    HotKeyCenter.shared.apply()
                }

                Text("Works from any app. If the shortcut does nothing, another app already owns it — pick a different one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scanning") {
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("5 seconds").tag(5.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                }
                .onChange(of: refreshInterval) { _, newValue in
                    Preferences.refreshInterval = newValue
                }

                Text("The panel refreshes faster while it's open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = "Open at login needs \(AppInfo.displayName) to be running from a signed app bundle in Applications."
        }
    }
}

// MARK: - Display

/// Everything that can be turned off, in one place. Rows carry a lot of live data,
/// and not everyone wants all of it moving on every refresh.
private struct DisplaySettings: View {
    @Bindable var store: ServerStore

    var body: some View {
        Form {
            Section {
                Picker("Rows", selection: $store.rowDensity) {
                    ForEach(RowDensity.allCases, id: \.self) { density in
                        Text(density.label).tag(density)
                    }
                }
                .pickerStyle(.segmented)

                Text(store.rowDensity.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("In each row") {
                Toggle("CPU and uptime", isOn: $store.showMetrics)
                    .disabled(store.rowDensity == .simple)
                Toggle("CPU history graph", isOn: $store.showSparklines)
                    .disabled(!store.showMetrics)
                Toggle("Git branch", isOn: $store.showGitBranch)
                Toggle("Page title", isOn: $store.showPageTitles)
                    .disabled(!store.healthProbeEnabled)
            }

            Section("When a row is expanded") {
                Toggle("Page preview", isOn: $store.previewsEnabled)

                Text("Previews render only for the row you expand, and only when you open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Motion") {
                Toggle("Reduce motion", isOn: $store.reduceMotion)

                Text("Stops the list animating when servers come and go. Values still update in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Checks") {
                Toggle("Check whether servers are responding", isOn: $store.healthProbeEnabled)

                Text("Adds the status code, response time, page title, and detects servers that hold a port without answering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

private struct AppsSettings: View {
    @State private var terminal = Preferences.terminalBundleID
    @State private var editor = Preferences.editorBundleID
    @State private var browser = Preferences.browserBundleID
    @State private var cloudflaredPath = Preferences.cloudflaredPath ?? ""
    @State private var rewriteHost = Preferences.rewriteTunnelHost

    var body: some View {
        Form {
            Section {
                Picker("Terminal", selection: $terminal) {
                    ForEach(AppLauncher.installed(.terminal)) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .onChange(of: terminal) { _, newValue in Preferences.terminalBundleID = newValue }

                Picker("Editor", selection: $editor) {
                    ForEach(AppLauncher.installed(.editor)) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .onChange(of: editor) { _, newValue in Preferences.editorBundleID = newValue }

                Picker("Browser", selection: $browser) {
                    Text("System default").tag(String?.none)
                    ForEach(AppLauncher.installed(.browser)) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .onChange(of: browser) { _, newValue in Preferences.browserBundleID = newValue }
            } footer: {
                Text("Only apps installed on this Mac are listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Public sharing") {
                if TunnelService.isInstalled {
                    Label(
                        TunnelService.executablePath() ?? "cloudflared",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Install cloudflared to share a port publicly:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("brew install cloudflared")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }

                TextField("Custom cloudflared path", text: $cloudflaredPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Preferences.cloudflaredPath = cloudflaredPath }

                Toggle("Send requests as localhost", isOn: $rewriteHost)
                    .onChange(of: rewriteHost) { _, newValue in
                        Preferences.rewriteTunnelHost = newValue
                    }

                Text("Dev servers reject unknown hostnames — Vite answers \"This host is not allowed\". This sends Host: localhost:<port> so they accept the request without you editing allowedHosts. Turn it off only if the app needs to see the public hostname.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Sharing opens a Cloudflare quick tunnel. The link is public, unauthenticated and temporary — it closes when you stop it, quit, or restart the app, and you get a new address next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ignore rules

private struct IgnoreSettings: View {
    let store: ServerStore

    @State private var ports = Preferences.ignoredPorts.sorted().map(String.init)
    @State private var commands = Preferences.ignoredCommands.sorted()
    @State private var targets = Preferences.ignoredTargets.sorted()
    @State private var newRule = ""
    @State private var ruleKind: RuleKind = .port

    private enum RuleKind: String, CaseIterable {
        case port = "Port"
        case app = "App"
        case project = "Project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.comfy) {
            HStack {
                Picker("", selection: $ruleKind) {
                    ForEach(RuleKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                TextField(placeholder, text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addRule)

                Button("Add", action: addRule)
                    .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            List {
                ruleSection("Ports", items: ports) { remove($0, from: .port) }
                ruleSection("Apps", items: commands) { remove($0, from: .app) }
                ruleSection("Projects and containers", items: targets) { remove($0, from: .project) }
            }
            .listStyle(.inset)
        }
        .padding(Theme.Space.loose)
    }

    private var placeholder: String {
        switch ruleKind {
        case .port: return "3000"
        case .app: return "ollama"
        case .project: return "~/dev/old-project"
        }
    }

    @ViewBuilder
    private func ruleSection(
        _ title: String,
        items: [String],
        remove: @escaping (String) -> Void
    ) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.self) { item in
                    HStack {
                        Text(item).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            remove(item)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func addRule() {
        let value = newRule.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }

        switch ruleKind {
        case .port:
            guard let port = Int(value) else { return }
            var current = Preferences.ignoredPorts
            current.insert(port)
            Preferences.ignoredPorts = current
            ports = current.sorted().map(String.init)
        case .app:
            var current = Preferences.ignoredCommands
            current.insert(value.lowercased())
            Preferences.ignoredCommands = current
            commands = current.sorted()
        case .project:
            var current = Preferences.ignoredTargets
            current.insert(value.lowercased())
            Preferences.ignoredTargets = current
            targets = current.sorted()
        }

        newRule = ""
        store.refresh(force: true)
    }

    private func remove(_ value: String, from kind: RuleKind) {
        switch kind {
        case .port:
            guard let port = Int(value) else { return }
            var current = Preferences.ignoredPorts
            current.remove(port)
            Preferences.ignoredPorts = current
            ports = current.sorted().map(String.init)
        case .app:
            var current = Preferences.ignoredCommands
            current.remove(value)
            Preferences.ignoredCommands = current
            commands = current.sorted()
        case .project:
            var current = Preferences.ignoredTargets
            current.remove(value)
            Preferences.ignoredTargets = current
            targets = current.sorted()
        }

        store.refresh(force: true)
    }
}
