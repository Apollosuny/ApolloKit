import ApolloKitCore
import AppKit
import SwiftUI

extension RuleGroup {
    /// System colors, one per category, as in the tiles of System Settings.
    var tint: Color {
        switch self {
        case .system: .gray
        case .apps: .cyan
        case .xcode: .blue
        case .packageManagers: .purple
        case .toolchains: .pink
        case .editors: .mint
        case .docker: .teal
        case .projectArtifacts: .indigo
        case .largeFiles: .brown
        }
    }

    /// What happens after cleaning, shown above a category's items.
    var explanation: String {
        switch self {
        case .system:
            "Apps and macOS recreate caches and logs as they need them. Emptying the Trash cannot be undone."
        case .apps:
            "Browsers and Electron apps rebuild their caches. Backups and data of removed apps are never selected for you."
        case .xcode:
            "Xcode recreates DerivedData and device support files the next time you build or connect a device. Simulator runtimes can be downloaded again in Xcode › Settings › Components."
        case .packageManagers:
            "Package managers download what they need again on the next install, which takes time and bandwidth but loses nothing."
        case .toolchains:
            "Your default versions are never listed. Removing a version also removes tools installed into it."
        case .editors:
            "Editors rebuild their caches and indexes on the next launch. Settings and extensions are kept."
        case .docker:
            "Docker removes these through its own CLI, so they skip the Trash. Images are pulled again when a container needs them."
        case .projectArtifacts:
            "Only build artifacts are removed. They come back with npm install, cargo build or pod install."
        case .largeFiles:
            "Installers, archives and disk images you may have forgotten. Nothing here is selected for you."
        }
    }
}

extension Color {
    /// The orange of the app icon's highlighted disk segment, used for the scan button and its progress.
    static let brandOrange = Color(red: 0.95, green: 0.55, blue: 0.16)
    static let brandOrangeLight = Color(red: 1.0, green: 0.71, blue: 0.33)
    /// The accent as text: darker in light mode and lighter in dark mode, so it stays readable on plain backgrounds.
    static let accentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.71, blue: 0.33, alpha: 1)
            : NSColor(red: 0.72, green: 0.35, blue: 0.02, alpha: 1)
    })
    static let usedSpace = Color(nsColor: .systemGray).opacity(0.55)
    /// The empty track of disk bars, which stands for available space.
    static let availableSpace = Color.primary.opacity(0.1)
}

extension Int64 {
    var fileSize: String { formatted(.byteCount(style: .file)) }
}

/// Rounded, tinted category icon in the style of System Settings.
struct GroupIcon: View {
    let group: RuleGroup
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: group.symbolName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(group.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Content surface for cards. Liquid Glass is reserved for controls, per Apple's guidance,
/// so content cards use a plain grouped background.
struct CardSurface: ViewModifier {
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06))
            }
    }
}

extension View {
    func cardSurface(highlighted: Bool = false) -> some View {
        modifier(CardSurface(isHighlighted: highlighted))
    }

    /// Prominent call-to-action: Liquid Glass on macOS 26, bordered-prominent before.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The clean bar's rounded panel: Liquid Glass on macOS 26, bar material before.
    @ViewBuilder
    func floatingPanelBackground(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.bar, in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        }
    }
}

/// Horizontal stacked bar in the spirit of System Settings › Storage.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    let totalBytes: Int64
    var height: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.bytes > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color.gradient)
                            .frame(width: max(2, proxy.size.width * fraction(of: segment.bytes)))
                            .help("\(segment.title): \(segment.bytes.fileSize)")
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: height)

            HStack(spacing: 14) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.title).foregroundStyle(.secondary)
                        Text(segment.bytes.fileSize).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func fraction(of bytes: Int64) -> CGFloat {
        totalBytes > 0 ? CGFloat(Double(bytes) / Double(totalBytes)) : 0
    }
}

/// Circular progress ring filled with the accent color.
struct ProgressRing<Center: View>: View {
    let fraction: Double
    var lineWidth: CGFloat = 9
    @ViewBuilder let center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.005, fraction)))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            center()
        }
        .padding(lineWidth / 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: - Safety

/// Safe is a green checkmark, Caution a yellow triangle; both always carry a word, so color is never the only signal.
struct SafetyLabel: View {
    let risk: RiskLevel
    var isPermanent = false

    var body: some View {
        HStack(spacing: 5) {
            switch risk {
            case .safe:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .green)
                Text("Safe")
            case .caution:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.black.opacity(0.85), .yellow)
                Text("Caution")
            }
            if isPermanent {
                Text("· Permanent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .symbolRenderingMode(.palette)
        .help(helpText)
    }

    private var helpText: String {
        var text = risk == .safe
            ? "Rebuilds by itself, so it is selected for you."
            : "Slow to rebuild or may hold something worth keeping. Never selected for you."
        if isPermanent { text += " Skips the Trash and cannot be undone." }
        return text
    }
}

/// The yellow triangle on its own, for counts such as "3 to review".
struct CautionGlyph: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black.opacity(0.85), .yellow)
            .accessibilityLabel("Caution")
    }
}

// MARK: - Surfaces

extension View {
    /// The rounded light-gray grouping of System Settings, for lists and summaries on a plain background.
    func groupedBox(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Hairline-bordered surface for tables and notices.
    func outlinedBox(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The gray capsule buttons of the design: secondary actions next to a prominent one.
    func capsuleButtonStyle() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
}

/// A one-line message with an icon tile, such as missing permissions or items that were skipped.
struct Notice<Actions: View>: View {
    enum Kind {
        case info
        case warning
    }

    let kind: Kind
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .info ? "info" : "exclamationmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(kind == .info ? Color.white : Color.black.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(kind == .info ? Color.blue : Color.yellow, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions()
                .capsuleButtonStyle()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .outlinedBox()
    }
}

/// Used, about to be freed and available space as one bar, as in System Settings › Storage.
struct DiskUsageBar: View {
    struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.bytes })
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2, (proxy.size.width - 1.5 * CGFloat(segments.count - 1)) * CGFloat(segment.bytes) / CGFloat(total)))
                }
            }
        }
        .frame(height: height)
        .background(.quaternary)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

struct LegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
    }
}

/// A checkbox for a set of items: on, off, or mixed when only part of it is selected.
struct SelectionCheckbox: View {
    enum State {
        case on, mixed, off

        init(selected: Int64, total: Int64) {
            self = selected == 0 ? .off : (selected >= total ? .on : .mixed)
        }
    }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .accessibilityValue(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }

    private var symbolName: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}
