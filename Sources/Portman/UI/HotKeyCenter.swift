import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut for opening the panel.
///
/// Uses Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`
/// on purpose: the monitor route needs Input Monitoring permission and a TCC prompt,
/// while this needs neither. It's old API, but it's still the only way to take a
/// global shortcut without asking the user for access to every keystroke they type.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Called on the main actor when the shortcut fires.
    var action: (() -> Void)?

    private init() {}

    func apply() {
        unregister()

        guard Preferences.hotKeyEnabled else { return }

        let shortcut = Preferences.hotKey
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x504D4752), id: 1)
        var reference: EventHotKeyRef?

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        // Fails when another app already owns the combination. Nothing to do about it
        // beyond letting the user pick a different one.
        guard status == noErr else { return }

        hotKeyRef = reference
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The callback is a C function pointer, so it can't capture context — it hops
        // to the main actor and goes through the singleton instead.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in
                    HotKeyCenter.shared.action?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }
}

/// The shortcuts on offer.
///
/// A fixed set rather than a recorder: a recorder is a lot of UI for something most
/// people set once, and a short list of combinations that are unlikely to be taken
/// avoids the conflict a single hardcoded default would cause.
enum HotKeyChoice: String, CaseIterable, Sendable {
    case optionCommandP
    case controlOptionP
    case shiftCommandP
    case optionCommandBackslash

    var label: String {
        switch self {
        case .optionCommandP: return "⌥⌘P"
        case .controlOptionP: return "⌃⌥P"
        case .shiftCommandP: return "⇧⌘P"
        case .optionCommandBackslash: return "⌥⌘\\"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionCommandP, .controlOptionP, .shiftCommandP:
            return UInt32(kVK_ANSI_P)
        case .optionCommandBackslash:
            return UInt32(kVK_ANSI_Backslash)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionCommandP, .optionCommandBackslash:
            return UInt32(optionKey | cmdKey)
        case .controlOptionP:
            return UInt32(controlKey | optionKey)
        case .shiftCommandP:
            return UInt32(shiftKey | cmdKey)
        }
    }
}
