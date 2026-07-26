import Foundation
import Sparkle

/// Wraps Sparkle, and stays switched off until a feed is actually configured.
///
/// The feed URL and the EdDSA public key come from the bundle's Info.plist, which the
/// build script fills in from `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY`. A build
/// without those — running from source, or a local `make publish-local` — simply has no
/// updater, rather than a broken one that errors when you ask it to check.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let windowObserver = UpdateWindowObserver()

    /// The version Sparkle has found on a check we didn't ask for, and which nothing has
    /// told the user about yet. The panel mentions it in the footer.
    private(set) var pendingUpdate: String?

    /// True when this build knows where to look for updates.
    var isConfigured: Bool {
        controller != nil
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// Runs immediately before Sparkle puts a window on screen, so the panel can get out
    /// from in front of it.
    @ObservationIgnored var onWillShowWindow: (@MainActor () -> Void)?

    private init() {
        guard Self.feedURL != nil, Self.publicKey != nil else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: windowObserver
        )

        windowObserver.willShowWindow = { [weak self] in
            self?.onWillShowWindow?()
        }

        windowObserver.foundQuietUpdate = { [weak self] version in
            self?.pendingUpdate = version
        }

        windowObserver.didFinishSession = { [weak self] in
            // Whatever the outcome — installed, skipped, put off — the reminder has done
            // its job. If it was deferred, Sparkle raises it again on its own schedule.
            self?.pendingUpdate = nil
        }
    }

    /// Asks for an update, and doubles as the way to bring an alert that's already on
    /// screen back to the front — which is what Sparkle's documentation prescribes.
    ///
    /// Callers inside the panel must dismiss it first. Sparkle only announces an alert it's
    /// about to show when the check was user-initiated, so re-focusing an alert it found on
    /// its own schedule tells us nothing, and the panel would cover the window it just
    /// asked for.
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
    var willShowWindow: (@MainActor () -> Void)?
    var foundQuietUpdate: (@MainActor (String) -> Void)?
    var didFinishSession: (@MainActor () -> Void)?

    /// Opts into Sparkle's gentle reminders.
    ///
    /// Without this, a scheduled check throws its dialog up unprompted — and for an
    /// accessory app that lands behind whatever you're working in, which Sparkle itself
    /// warns about: "users may not take notice to update alerts that show up in the
    /// background". An update is never urgent enough to interrupt for.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `false` means "don't show it, we will".
    ///
    /// Only consulted for checks the user didn't ask for. A check they *did* ask for is
    /// always Sparkle's to present, which is right — they're standing there waiting for an
    /// answer.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else {
            // Ours to mention. Nothing of Sparkle's is about to appear, so the panel stays
            // where it is — this is the quiet path.
            let version = update.displayVersionString
            MainActor.assumeIsolated { foundQuietUpdate?(version) }
            return
        }

        notifyWillShowWindow()
    }

    func standardUserDriverWillShowModalAlert() {
        notifyWillShowWindow()
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { didFinishSession?() }
    }

    /// Sparkle calls these on the main thread, immediately before the window appears.
    ///
    /// Run synchronously rather than hopping through a `Task`: a modal alert spins its
    /// own run loop, which doesn't service queued main-actor work, so the hop wouldn't
    /// land until the alert was dismissed — leaving the panel on top for exactly as long
    /// as it matters.
    private func notifyWillShowWindow() {
        MainActor.assumeIsolated {
            willShowWindow?()
        }
    }
}
