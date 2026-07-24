import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ServerStore.shared
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panelController = PanelController(store: store)
        store.start()

        // Lets a screenshot or a UI check drive the panel without a real click.
        if ProcessInfo.processInfo.environment["PORTMANAGER_OPEN_ON_LAUNCH"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                panelController?.open()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.panelDidClose()
    }
}
