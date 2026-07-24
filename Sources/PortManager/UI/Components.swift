import SwiftUI

// MARK: - Status dot

struct StatusDot: View {
    let entry: ServerEntry

    var body: some View {
        Circle()
            .fill(Theme.Colour.dot(for: entry))
            .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
            .overlay {
                // A hung server gets a ring so it reads differently from healthy
                // even for someone who can't separate green from orange.
                if entry.health?.state == .hung {
                    Circle().strokeBorder(Theme.Colour.hung, lineWidth: 1.5).scaleEffect(1.7)
                }
            }
            .help(healthDescription)
    }

    private var healthDescription: String {
        switch entry.state {
        case .staleWorktree: return "Project files are gone — stale worktree"
        case .orphan: return "Project folder is missing"
        case .active: break
        }

        switch entry.health?.state {
        case .hung: return "Holding the port but not responding"
        case .healthy: return "Responding"
        case .nonHTTP: return "Listening (not HTTP)"
        case .refused: return "Connection refused"
        default: return "Listening"
        }
    }
}

// MARK: - Chip

/// Small pill used for frameworks, Docker, and state callouts.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.Typography.badge)
            .foregroundStyle(filled ? tint : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip - 2)
                    .fill(filled ? tint.opacity(0.14) : Theme.Colour.chipFill)
            )
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let label: String
    let isActive: Bool
    let count: Int?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if let count, count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(Theme.Typography.button)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, Theme.Space.regular)
            .padding(.vertical, Theme.Space.tight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) { isHovered = hovering }
        }
    }

    private var background: Color {
        if isActive { return Theme.Colour.chipFillActive }
        return isHovered ? Theme.Colour.chipFill : .clear
    }
}

// MARK: - Meta label

/// One `icon + value` pair on a row's second line.
struct MetaLabel: View {
    let symbol: String?
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9))
            }
            Text(text)
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(tint ?? .secondary)
    }
}

// MARK: - Action button

struct ActionButton: View {
    let label: String
    var symbol: String?
    var destructive = false
    var prominent = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                }
                Text(label)
            }
            .font(Theme.Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.regular)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) { isHovered = hovering }
        }
    }

    private var foreground: Color {
        if destructive { return isHovered ? .white : Theme.Colour.destructive }
        if prominent { return isHovered ? .white : .accentColor }
        return .primary
    }

    private var background: Color {
        if destructive { return isHovered ? Theme.Colour.destructive : Theme.Colour.destructive.opacity(0.12) }
        if prominent { return isHovered ? .accentColor : Color.accentColor.opacity(0.14) }
        return isHovered ? Theme.Colour.chipFill.opacity(2) : Theme.Colour.chipFill
    }
}

// MARK: - Icon button

struct IconButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(destructive && isHovered ? Theme.Colour.destructive : .secondary)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip - 1)
                        .fill(isHovered ? Theme.Colour.chipFill : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) { isHovered = hovering }
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var count: Int?
    var isCollapsed: Bool?
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            if let isCollapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.tertiary)
            }

            Text(title.uppercased())
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.secondary)
                .kerning(0.4)

            if let count {
                Text("\(count)")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, Theme.Space.comfy)
        .padding(.bottom, Theme.Space.tight)
        .contentShape(Rectangle())
        .onTapGesture { toggle?() }
    }
}

// MARK: - Sparkline

/// Tiny CPU history trace. Deliberately unlabelled — it's a texture that shows
/// "busy or idle" at a glance, and the exact number is right next to it.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .secondary

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(values.max() ?? 1, 1)
            let step = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * step
                    let y = geometry.size.height * (1 - CGFloat(value / maximum))
                    let point = CGPoint(x: x, y: y)

                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Theme.Size.sparklineWidth, height: Theme.Size.sparklineHeight)
    }
}

// MARK: - Panel background

/// Liquid Glass on Tahoe, a plain material everywhere else.
struct PanelBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius)
                .fill(.ultraThinMaterial)
                .glassEffect(in: .rect(cornerRadius: Theme.Panel.cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius)
                .fill(.ultraThinMaterial)
        }
    }
}
