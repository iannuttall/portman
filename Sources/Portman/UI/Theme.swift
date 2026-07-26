import AppKit
import SwiftUI

/// Every spacing, radius, size and semantic colour the panel uses.
///
/// One place to tune the whole look. Views should never hardcode a number that
/// belongs here — if a value is used twice, it earns a token.
enum Theme {
    // MARK: Panel

    enum Panel {
        static let width: CGFloat = 400
        static let maxHeight: CGFloat = 620
        /// Tall enough that an expanded row — preview included — is never clipped.
        static let minHeight: CGFloat = 430
        /// Search field, filter row and footer, i.e. everything that isn't the list.
        static let chrome: CGFloat = 118
        static let cornerRadius: CGFloat = 12
        /// Gap between the menu bar and the top of the panel.
        static let menuBarGap: CGFloat = 6
    }

    // MARK: Spacing

    enum Space {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let regular: CGFloat = 8
        static let comfy: CGFloat = 12
        static let loose: CGFloat = 16

        /// Horizontal inset shared by the header, rows and footer so everything
        /// lines up on one left edge.
        static let gutter: CGFloat = 12
    }

    // MARK: Radii

    enum Radius {
        static let chip: CGFloat = 6
        static let row: CGFloat = 8
        static let card: CGFloat = 10
        static let thumbnail: CGFloat = 8
    }

    // MARK: Sizes

    enum Size {
        static let statusDot: CGFloat = 7
        static let rowHeight: CGFloat = 44
        static let iconColumn: CGFloat = 18
        static let thumbnailHeight: CGFloat = 132
        static let sparklineWidth: CGFloat = 40
        static let sparklineHeight: CGFloat = 12

        /// The status item's alert dot: big enough to register in peripheral vision,
        /// small enough not to compete with the system's own icons.
        static let menuBarBadge: CGFloat = 9
        /// Transparent ring separating the dot from the plug underneath it.
        static let menuBarBadgeMoat: CGFloat = 1
        /// How far the dot hangs past the plug's right edge. Most of the dot sits *on* the
        /// plug, so its moat cuts a visible notch out of the corner — a dot floating clear
        /// of the icon just looks like a separate stray item in the menu bar.
        static let menuBarBadgeOverhang: CGFloat = 3
    }

    // MARK: Type

    enum Typography {
        static let title = Font.system(size: 13, weight: .medium)
        static let port = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let subtitle = Font.system(size: 11)
        static let meta = Font.system(size: 11)
        static let metaMono = Font.system(size: 11, design: .monospaced)
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        static let badge = Font.system(size: 10, weight: .medium)
        static let button = Font.system(size: 11, weight: .medium)
    }

    // MARK: Colour

    enum Colour {
        static let healthy = Color.green
        /// The port reads as a link-ish accent, like the reference design.
        static let port = Color.green
        static let hung = Color.orange
        /// Both abandoned states share one colour. Yellow was unreadable against the
        /// panel material, and "stale" vs "orphan" is a distinction the label already
        /// makes — it doesn't need a second channel.
        static let stale = Color(red: 0.72, green: 0.42, blue: 0.05)
        static let orphan = Color(red: 0.72, green: 0.42, blue: 0.05)
        static let destructive = Color.red
        static let inert = Color.secondary.opacity(0.5)

        /// The status item's alert colour, and the one place the app draws in the menu
        /// bar with a colour of its own — see the template-image note in
        /// `PanelController` for why that's an exception rather than a slip.
        ///
        /// A system colour, not `stale`'s fixed RGB: the status item has to stay legible
        /// against a light *and* a dark menu bar, and only the system oranges carry both
        /// variants. Orange rather than red because none of these are emergencies —
        /// they're things to look at, and red is reserved for kill.
        static let menuBarAlert = NSColor.systemOrange

        static let rowHover = Color.primary.opacity(0.06)
        static let rowSelected = Color.accentColor.opacity(0.14)
        static let chipFill = Color.primary.opacity(0.07)
        static let chipFillActive = Color.accentColor.opacity(0.16)
        static let cardFill = Color.primary.opacity(0.04)
        static let separator = Color.primary.opacity(0.08)

        static func dot(for entry: ServerEntry) -> Color {
            switch entry.state {
            case .staleWorktree, .orphan:
                return stale
            case .active:
                break
            }

            switch entry.health?.state {
            case .hung:
                return hung
            case .refused:
                return inert
            default:
                return healthy
            }
        }
    }

    // MARK: Motion

    enum Motion {
        static let hover = SwiftUI.Animation.easeInOut(duration: 0.12)
        static let expand = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.82)
        static let listUpdate = SwiftUI.Animation.easeInOut(duration: 0.22)
        static let kill = SwiftUI.Animation.easeOut(duration: 0.28)

        /// The status item's one-shot blink when a problem first appears. Asymmetric on
        /// purpose: short off, longer on, so the icon spends most of the blink showing
        /// the badge rather than looking like it's flickering out.
        static let menuBarFlashBeats = 2
        static let menuBarFlashOff = Duration.milliseconds(110)
        static let menuBarFlashOn = Duration.milliseconds(190)
    }
}

// MARK: - Formatting

/// Shared formatters so `4h 12m`, `512 MB` and `2.1%` read the same everywhere.
enum Format {
    static func uptime(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(max(seconds, 0))s" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }

        return "\(hours / 24)d \(hours % 24)h"
    }

    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 {
            return "\(Int(megabytes.rounded())) MB"
        }
        return String(format: "%.1f GB", megabytes / 1024)
    }

    static func cpu(_ percent: Double) -> String {
        percent < 10
            ? String(format: "%.1f%%", percent)
            : "\(Int(percent.rounded()))%"
    }

    static func latency(_ interval: TimeInterval) -> String {
        let milliseconds = interval * 1000
        if milliseconds < 1000 {
            return "\(Int(milliseconds.rounded()))ms"
        }
        return String(format: "%.1fs", interval)
    }

    /// `—` is the honest answer for a process we can't read, and it must never be `0`.
    static let unavailable = "—"
}
