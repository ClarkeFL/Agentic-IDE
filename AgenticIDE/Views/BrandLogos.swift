import SwiftUI

/// Lightweight, asset-free approximations of the Claude and Codex marks.
/// They're drawn with SwiftUI primitives so we don't have to ship logo PNGs.

struct ClaudeLogo: View {
    var size: CGFloat = 16
    /// Anthropic's "Claude coral" — close enough for a sidebar glyph.
    var color: Color = Color(red: 0.85, green: 0.46, blue: 0.34)

    var body: some View {
        ZStack {
            // 8-spoke asterisk: 4 bidirectional capsules at 0/45/90/135.
            ForEach(0..<4) { i in
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.18, height: size * 0.95)
                    .rotationEffect(.degrees(Double(i) * 45.0))
            }
        }
        .frame(width: size, height: size)
    }
}

/// OpenAI/Codex-style mark: three overlapping ellipses rotated 60°,
/// stroked. Reads as the rosette at small sizes.
struct CodexLogo: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Ellipse()
                    .stroke(color, lineWidth: max(1.0, size * 0.09))
                    .frame(width: size * 0.95, height: size * 0.42)
                    .rotationEffect(.degrees(Double(i) * 60.0))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Resolve a QuickLaunch's icon string to a view. Strings prefixed `brand:`
/// render a custom logo; everything else is treated as an SF Symbol.
@ViewBuilder
func quickLaunchIcon(name: String?, size: CGFloat = 16) -> some View {
    if let name {
        switch name {
        case "brand:claude":
            ClaudeLogo(size: size)
        case "brand:codex":
            CodexLogo(size: size)
        default:
            Image(systemName: name)
                .font(.system(size: size * 0.9, weight: .medium))
        }
    } else {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.9, weight: .medium))
    }
}
