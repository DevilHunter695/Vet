import SwiftUI

// MARK: - Floating chrome
//
// Apple Music's screens do not have a navigation *bar*. They have a large
// title in the content, and a few circular glass controls floating over it —
// so the top of the screen is content, not a reserved strip with a hairline
// under it. That is what makes those screens feel like they start at the top
// of the display instead of 96pt down.
//
// These are the pieces for doing the same here.

/// A circular glass control. 44pt, because a 28pt glyph in a 28pt circle is
/// the single most reliable way to make a control that people miss.
struct GlassIconButton: View {
    let systemImage: String
    var accessibilityTitle: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? Theme.textPrimary)
                .frame(width: 44, height: 44)
                .glassCircle(level: .chrome)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .accessibilityLabel(accessibilityTitle)
    }
}

/// Two or more controls sharing one glass capsule, the way Apple Music groups
/// `+` and the sort button. Grouping related controls in one surface says they
/// belong together far more clearly than spacing them evenly does.
struct GlassControlGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .glassCapsule(level: .chrome)
        .clipShape(Capsule(style: .continuous))
    }
}

/// A control designed to sit inside `GlassControlGroup` — no glass of its own,
/// because stacking a translucent surface on another destroys legibility.
struct GlassGroupButton: View {
    let systemImage: String
    var accessibilityTitle: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 46, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressStyle())
        .accessibilityLabel(accessibilityTitle)
    }
}

struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1.0), value: configuration.isPressed)
    }
}

/// The large title, in the content rather than in a navigation bar.
///
/// Tracking is negative and leading is tight, because both are size-specific:
/// at display sizes letters read too far apart and lines too far down. A
/// single `letter-spacing` applied at every size is wrong somewhere, and at
/// this size the wrongness is visible.
struct LargeTitle: View {
    let text: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.8)
                .lineSpacing(-2)
                .foregroundStyle(Theme.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Scroll edge
//
// Where floating chrome overlaps scrolling content, a hard divider is the
// wrong tool — it draws a line across content that is meant to pass beneath.
// A short gradient mask fades the content out under the chrome instead, only
// where they actually overlap.

extension View {
    /// Fades the top of a scroll view out behind floating controls.
    func scrollEdgeFade(height: CGFloat = 90) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height)
                Rectangle().fill(.black)
            }
        )
    }
}
