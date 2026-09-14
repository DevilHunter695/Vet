import SwiftUI
import UIKit

// MARK: - Haptics
// Distinct feedback per meaning, not one impact style everywhere — per the
// "multimodal feedback" principle: causality (fire on the actual event),
// harmony (same frame as the visual change), utility (earn its place).
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A deliberate, weightier action — confirming a booking, sending a payment.
    static func confirm() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// A genuinely rare, celebratory moment — booking confirmed, great review submitted.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// A sharp, mechanical click — snapping to a discrete step (a stepper
    /// increment, a slider hitting a notch), distinct from a soft tap.
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// A muted, gentle thud — background/ambient events (a message arriving
    /// while the screen is already open) that shouldn't compete with the
    /// weight of a deliberate tap.
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}

// MARK: - Brand design system
// A small, deliberate palette + motion language, applied consistently
// instead of relying on default system styling everywhere.

enum Theme {
    // Deep teal + warm coral: calm/trustworthy (healthcare) with a warm,
    // friendly accent (pets) — distinct from generic iOS blue.
    static let primary = Color(hue: 0.52, saturation: 0.55, brightness: 0.55)      // deep teal
    static let primaryLight = Color(hue: 0.52, saturation: 0.45, brightness: 0.72)
    static let accent = Color(hue: 0.04, saturation: 0.78, brightness: 0.95)       // warm coral
    static let accentSoft = Color(hue: 0.04, saturation: 0.35, brightness: 0.98)

    static let gradient = LinearGradient(
        colors: [primary, primaryLight],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [primary, Color(hue: 0.56, saturation: 0.6, brightness: 0.38)],
        startPoint: .top, endPoint: .bottom
    )

    static let cardShadow = Color.black.opacity(0.08)

    // Semantic status colors, tuned to sit alongside the teal/coral brand
    // instead of clashing system defaults (a raw system .orange reads harsh
    // and disconnected next to a warm-coral accent).
    static let warning = Color(hue: 0.09, saturation: 0.7, brightness: 0.92)   // warm amber, not traffic-cone orange
    static let danger = Color(hue: 0.0, saturation: 0.72, brightness: 0.88)    // clear, unambiguous red
    static let success = Color(hue: 0.38, saturation: 0.55, brightness: 0.62)  // muted green, matches the palette's saturation
    static let inProgress = Color(hue: 0.72, saturation: 0.45, brightness: 0.72) // soft violet, distinct from primary teal
    static let neutral = Color(.systemGray)

    // Loyalty tier colors — a distinct family from status colors above
    // (achievement tiers, not urgency/state), tuned to the same saturation
    // level as the rest of the palette instead of raw system .orange/.yellow.
    static let bronzeTier = Color(hue: 0.07, saturation: 0.55, brightness: 0.72)  // warm copper
    static let silverTier = Color(hue: 0.58, saturation: 0.06, brightness: 0.72)  // cool metallic gray
    static let goldTier = Color(hue: 0.12, saturation: 0.65, brightness: 0.88)    // rich gold

    // Motion language, tuned against Apple's fluid-interfaces defaults and
    // Emil Kowalski's animation standards:
    //  - critically damped (no bounce) for anything fired many times/day
    //    (button presses, toggles) — bounce is earned, not default
    //  - a little bounce only for rare/occasional delight moments
    //    (entrances, celebrations), kept under ~400ms response
    //  - never `ease-in` on UI — it delays the moment users are watching most
    static let springQuick = Animation.spring(response: 0.28, dampingFraction: 1.0)
    static let springSoft = Animation.spring(response: 0.4, dampingFraction: 0.86)
    static let springMomentum = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let crossFade = Animation.easeOut(duration: 0.25)

    /// Stagger delay for the nth item in a list entrance, capped so a long
    /// list doesn't push its later rows into a slow, sluggish-feeling reveal.
    static func staggerDelay(_ index: Int) -> Double {
        Double(min(index, 6)) * 0.05
    }
}

// MARK: - Typography

extension Font {
    static let brandLargeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let brandTitle = Font.system(.title2, design: .rounded, weight: .bold)
    static let brandHeadline = Font.system(.headline, design: .rounded, weight: .semibold)
    static let brandBody = Font.system(.body, design: .rounded)
    static let brandCaption = Font.system(.caption, design: .rounded, weight: .medium)
}

extension View {
    /// Apple's typography guidance: tracking is size-specific, never one
    /// fixed value. Large display text reads too loose at full tracking, so
    /// tighten it as size grows; leave body/caption text near zero.
    func brandDisplayText() -> some View {
        self.tracking(-0.5)
    }
}

// MARK: - Press animation modifier — subtle scale + shadow lift on tap

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Without this, taps only register on the label's non-transparent
            // children (text/icons) — any Spacer() or background-only area in
            // a row's HStack/VStack silently ignores taps. Applying it here,
            // centrally, makes every row using this style tappable across its
            // whole visual bounds instead of only its intrinsic content.
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.springQuick, value: configuration.isPressed)
    }
}

extension View {
    /// Fades and scales a view in — use on hero content and cards appearing on screen.
    func appearAnimation(delay: Double = 0) -> some View {
        modifier(AppearAnimationModifier(delay: delay))
    }
}

private struct AppearAnimationModifier: ViewModifier {
    let delay: Double
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : 0.92))
            .onAppear {
                if reduceMotion {
                    isVisible = true
                } else {
                    withAnimation(Theme.springSoft.delay(delay)) { isVisible = true }
                }
            }
    }
}

// MARK: - Shimmering loading placeholder (used while data streams in)

struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.5), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .rotationEffect(.degrees(20))
                .offset(x: phase * 200)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}
