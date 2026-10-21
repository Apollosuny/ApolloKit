import ApolloKitCore
import SwiftUI

extension RuleGroup {
    var tint: Color {
        switch self {
        case .system: .gray
        case .apps: .teal
        case .xcode: .blue
        case .packageManagers: .orange
        case .toolchains: .purple
        case .editors: .indigo
        case .docker: .cyan
        case .projectArtifacts: .green
        }
    }
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

    /// Floating bar background: Liquid Glass on macOS 26, bar material before.
    @ViewBuilder
    func floatingBarBackground() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.bar, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08)) }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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

/// Circular progress ring; indeterminate (spinning arc) when `fraction` is nil.
struct ProgressRing<Center: View>: View {
    let fraction: Double?
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 14
    @ViewBuilder let center: () -> Center

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction.map { max(0.02, $0) } ?? 0.25)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.4), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(fraction == nil ? rotation : -90))
                .animation(.smooth, value: fraction)
            center()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
