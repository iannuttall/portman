import AppKit
import Foundation

extension PortManagerApp {
    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }

        ignoredPortsTextView?.string = ignoredPorts.map(String.init).sorted().joined(separator: "\n")
        ignoredCommandsTextView?.string = ignoredCommands.sorted().joined(separator: "\n")
        ignoredTargetsTextView?.string = ignoredTargets.sorted().joined(separator: "\n")

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Port Manager Settings"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let title = NSTextField(labelWithString: "Ignore Rules")
        title.font = .boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: 24, y: 382, width: 240, height: 24)
        contentView.addSubview(title)

        let detail = NSTextField(labelWithString: "One value per line. Matching ports, app commands, projects, and Docker containers are hidden from the menu.")
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 24, y: 350, width: 510, height: 34)
        detail.cell?.wraps = true
        contentView.addSubview(detail)

        let ports = makeSettingsTextView(label: "Ports", frame: NSRect(x: 24, y: 118, width: 120, height: 200), in: contentView)
        let commands = makeSettingsTextView(label: "Apps / commands", frame: NSRect(x: 160, y: 118, width: 170, height: 200), in: contentView)
        let targets = makeSettingsTextView(label: "Projects / containers", frame: NSRect(x: 346, y: 118, width: 188, height: 200), in: contentView)

        ignoredPortsTextView = ports
        ignoredCommandsTextView = commands
        ignoredTargetsTextView = targets

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 454, y: 24, width: 80, height: 32)
        contentView.addSubview(saveButton)

        let resetButton = NSButton(title: "Clear All", target: self, action: #selector(clearSettings))
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: 360, y: 24, width: 82, height: 32)
        contentView.addSubview(resetButton)

        return window
    }

    func makeSettingsTextView(label: String, frame: NSRect, in contentView: NSView) -> NSTextView {
        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: frame.minX, y: frame.maxY + 8, width: frame.width, height: 18)
        contentView.addSubview(labelField)

        let scrollView = NSScrollView(frame: frame)
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        contentView.addSubview(scrollView)
        return textView
    }

    @objc func saveSettings() {
        ignoredPorts = Set(parseSettingsList(ignoredPortsTextView?.string ?? "").compactMap(Int.init))
        ignoredCommands = Set(parseSettingsList(ignoredCommandsTextView?.string ?? "").map { $0.lowercased() })
        ignoredTargets = Set(parseSettingsList(ignoredTargetsTextView?.string ?? "").map { $0.lowercased() })
        settingsWindow?.close()
        rebuildMenu()
    }

    @objc func clearSettings() {
        ignoredPorts = []
        ignoredCommands = []
        ignoredTargets = []
        ignoredPortsTextView?.string = ""
        ignoredCommandsTextView?.string = ""
        ignoredTargetsTextView?.string = ""
        rebuildMenu()
    }

    func parseSettingsList(_ string: String) -> [String] {
        string
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
