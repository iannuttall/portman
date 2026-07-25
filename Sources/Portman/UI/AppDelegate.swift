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

        panelController = PanelController(store: store)
        store.start()

        // Lets a screenshot or a UI check drive the panel without a real click.
        // "expand" also opens the first row, so the detail card can be inspected.
        let debugOpen = ProcessInfo.processInfo.environment["PORTMAN_OPEN_ON_LAUNCH"]

        if debugOpen == "settings" {
            SettingsWindow.shared.show(store: store)
            return
        }

        if debugOpen == "1" || debugOpen == "expand" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                panelController?.open()

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
