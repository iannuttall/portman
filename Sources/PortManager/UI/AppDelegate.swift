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
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.panelDidClose()
    }
}
