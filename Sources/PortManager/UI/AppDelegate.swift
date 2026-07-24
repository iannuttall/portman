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
        // "expand" also opens the first row, so the detail card can be inspected.
        let debugOpen = ProcessInfo.processInfo.environment["PORTMANAGER_OPEN_ON_LAUNCH"]

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

    func applicationWillTerminate(_ notification: Notification) {
        store.panelDidClose()
    }
}
