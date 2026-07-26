import Foundation
import Sparkle

/// Wraps Sparkle, and stays switched off until a feed is actually configured.
///
/// The feed URL and the EdDSA public key come from the bundle's Info.plist, which the
/// build script fills in from `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY`. A build
/// without those — running from source, or a local `make publish-local` — simply has no
/// updater, rather than a broken one that errors when you ask it to check.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController?
    private let windowObserver = UpdateWindowObserver()

    /// True when this build knows where to look for updates.
    var isConfigured: Bool {
        controller != nil
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// Runs immediately before Sparkle puts a window on screen, so the panel can get out
    /// from in front of it.
    var onWillShowWindow: (@MainActor () -> Void)? {
        get { windowObserver.onWillShowWindow }
        set { windowObserver.onWillShowWindow = newValue }
    }

    private init() {
        guard Self.feedURL != nil, Self.publicKey != nil else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: windowObserver
        )
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    // MARK: - Configuration

    private static var feedURL: String? {
        value(for: "SUFeedURL")
    }

    private static var publicKey: String? {
        value(for: "SUPublicEDKey")
    }

    private static func value(for key: String) -> String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty,
            // The build script writes a placeholder when the variable isn't set.
            !value.hasPrefix("REPLACE_")
        else {
            return nil
        }

        return value
    }
}

/// Announces that Sparkle is about to show something.
///
/// The panel sits at `.popUpMenu` level, which outranks every ordinary window, so an
/// update dialog opens *behind* it — readable only after you've dismissed the panel by
/// hand, which is not obvious when a dialog you can't reach has just appeared.
///
/// Both hooks are needed: one fires for the update dialog itself, the other for the
/// modal alerts — "you're up to date", and the failures.
/// `@unchecked Sendable` because Sparkle's delegate protocol is not actor-isolated, and
/// satisfying it from a `@MainActor` type isn't possible. The callback is set once at
/// launch from the main actor and read on the main thread, which is the only thread
/// Sparkle delivers these on.
private final class UpdateWindowObserver: NSObject, SPUStandardUserDriverDelegate, @unchecked Sendable {
    var onWillShowWindow: (@MainActor () -> Void)?

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // False means Sparkle is handing the update to us to present, and nothing of its
        // own is about to appear for the panel to be in front of.
        guard handleShowingUpdate else { return }
        willShowWindow()
    }

    func standardUserDriverWillShowModalAlert() {
        willShowWindow()
    }

    /// Sparkle calls these on the main thread, immediately before the window appears.
    ///
    /// Run synchronously rather than hopping through a `Task`: a modal alert spins its
    /// own run loop, which doesn't service queued main-actor work, so the hop wouldn't
    /// land until the alert was dismissed — leaving the panel on top for exactly as long
    /// as it matters.
    private func willShowWindow() {
        MainActor.assumeIsolated {
            onWillShowWindow?()
        }
    }
}
