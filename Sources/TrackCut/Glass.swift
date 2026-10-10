import SwiftUI
import TrackCutCore

// Liquid Glass is available from macOS 26. On earlier systems these fall back to materials and the
// classic button styles.

extension View {
    /// A Liquid Glass background in `shape`. Interactive glass reacts to the pointer, for controls.
    @ViewBuilder
    func glassSurface(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    /// The prominent (tinted) button style: glass on macOS 26 and later
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// The standard button style: glass on macOS 26 and later
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Lets neighbouring glass shapes blend into each other on macOS 26 and later
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Icon button for the glass control bars
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, size: size)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0)))
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// Small picture of a fade: a ramp that rises (fade-in) or falls (fade-out) along the curve
struct FadeGlyph: Shape {
    var curve: FadeCurve = .linear
    var isFadeOut = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 24
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let gain = curve.gain(isFadeOut ? 1 - progress : progress)
            path.addLine(to: CGPoint(x: rect.minX + rect.width * progress, y: rect.maxY - rect.height * gain))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
