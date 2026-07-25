import Foundation

/// The app's own identity, in one place.
///
/// Read from the bundle where possible so a rename or a change of signing account
/// doesn't need a source change — the build script sets both.
enum AppInfo {
    static let displayName = "portman"

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "is.ian.portman"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Namespace for caches on disk. Falls back to a literal when running outside a
    /// bundle, which is what `swift run` does.
    static var cacheNamespace: String {
        Bundle.main.bundleIdentifier ?? "is.ian.portman"
    }
}
