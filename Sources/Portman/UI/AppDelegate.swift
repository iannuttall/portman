import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ServerStore.shared
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // A quick tunnel lives and dies with its cloudflared process, so a previous
        // crash can leave one holding a public URL that nothing is tracking.
        TunnelService.killOrphans()

        let panel = PanelController(store: store)
        panelController = panel

        // The panel outranks every ordinary window, so it has to get out of the way
        // before Sparkle opens one behind it. Touching the updater here also starts it
        // at launch rather than the first time the panel is opened, which is what lets a
        // scheduled check run for someone who hasn't opened the panel today.
        UpdateController.shared.onWillShowWindow = { [weak panel] in
            panel?.close()
        }

        store.start()

        // Lets a screenshot or a UI check drive the panel without a real click.
        // "expand" also opens the first row, so the detail card can be inspected.
        // "update" opens the panel and then asks for an update, which is the only way to
        // check that Sparkle's window doesn't open behind it — the panel's menu can't be
        // reached by accessibility.
        let debugOpen = ProcessInfo.processInfo.environment["PORTMAN_OPEN_ON_LAUNCH"]

        if debugOpen == "settings" {
            SettingsWindow.shared.show(store: store)
            return
        }

        if debugOpen == "1" || debugOpen == "expand" || debugOpen == "update" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                panelController?.open()

                if debugOpen == "update" {
                    // Long enough that the panel is unambiguously up first. The whole
                    // point is that Sparkle's window arrives over an already-open panel.
                    try? await Task.sleep(for: .seconds(2))
                    UpdateController.shared.checkForUpdates()
                    return
                }

                guard debugOpen == "expand" else { return }

                try? await Task.sleep(for: .seconds(2))
                if let first = store.rows.first {
                    store.selectedRowID = first.id
                    store.toggleExpanded(first.id)
                }
            }
        }
    }

    /// Tunnels must not outlive the app — quitting has to close the public door.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !store.tunnels.isEmpty else { return .terminateNow }

        Task { @MainActor in
            await store.stopAllTunnels()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.panelDidClose()
    }
}
