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

    /// True when this build knows where to look for updates.
    var isConfigured: Bool {
        controller != nil
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    private init() {
        guard Self.feedURL != nil, Self.publicKey != nil else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
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
