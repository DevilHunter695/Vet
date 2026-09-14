import SwiftUI
import UIKit

// MARK: - Haptics
// Distinct feedback per meaning, not one impact style everywhere — per the
// "multimodal feedback" principle: causality (fire on the actual event),
// harmony (same frame as the visual change), utility (earn its place).
//
// Generators are prepared lazily and kept alive: constructing a fresh
// `UIFeedbackGenerator` at the moment of the tap costs the Taptic Engine a
// spin-up, which is exactly the latency Apple's "kill latency" rule warns
// about — the first tap after a quiet period feels mushy or drops entirely.
// `UIFeedbackGenerator`'s initialisers are main-actor isolated, so holding
// them as stored statics requires the whole enum to be too. Every call site is
// a view body, a button action or a @MainActor view model, so this costs
// nothing and is more honest than the previous construct-one-per-tap version.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Call before a gesture that is *about* to produce feedback (e.g. on
    /// touch-down, ahead of the action firing) so the engine is already warm.
    static func prepare() {
        light.prepare()
        medium.prepare()
        selectionGenerator.prepare()
    }

    static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// A deliberate, weightier action — confirming a booking, sending a payment.
    static func confirm() {
        medium.impactOccurred()
        medium.prepare()
    }

    /// A genuinely rare, celebratory moment — booking confirmed, great review submitted.
    static func success() {
        notification.notificationOccurred(.success)
    }

    static func warning() {
        notification.notificationOccurred(.warning)
    }

    static func error() {
        notification.notificationOccurred(.error)
    }

    /// A sharp, mechanical click — snapping to a discrete step (a stepper
    /// increment, a slider hitting a notch), distinct from a soft tap.
    static func rigid() {
        rigidGenerator.impactOccurred()
        rigidGenerator.prepare()
    }

    /// A muted, gentle thud — background/ambient events (a message arriving
    /// while the screen is already open) that shouldn't compete with the
    /// weight of a deliberate tap.
    static func soft() {
        softGenerator.impactOccurred()
        softGenerator.prepare()
    }
}

// MARK: - Brand design system
//
// The palette is an "aurora": deep ocean blue bleeding into emerald green and
// falling away to near-black. Blue and green sit adjacent on the wheel, so a
// gradient between them stays harmonious at every stop instead of muddying
// through grey the way complementary pairs do — and both read as calm and
// clinical, which is what a healthcare product wants. The near-black floor
// gives the two hues somewhere to resolve, so a full-bleed background has
// depth rather than looking like a flat wash.
//
// One warm accent (coral) survives from the old palette and is used sparingly:
// against a cool blue/green field a single warm hue is where the eye goes, so
// it is reserved for the moments that should pull attention.

enum Theme {

    // MARK: Core hues

    /// Deep ocean blue — the primary brand hue and the anchor of the aurora.
    static let primary = Color(hue: 0.556, saturation: 0.72, brightness: 0.62)
    static let primaryLight = Color(hue: 0.545, saturation: 0.55, brightness: 0.82)
    static let primaryDeep = Color(hue: 0.585, saturation: 0.85, brightness: 0.36)

    /// Emerald — the second pole of the aurora. Used for "good" states,
    /// savings, credits, and anything that should read as healthy.
    static let emerald = Color(hue: 0.425, saturation: 0.68, brightness: 0.62)
    static let emeraldLight = Color(hue: 0.415, saturation: 0.52, brightness: 0.80)
    static let emeraldDeep = Color(hue: 0.445, saturation: 0.80, brightness: 0.34)

    /// The floor the aurora falls away to. Not pure black — a hair of blue
    /// keeps it from looking like a dead pixel field next to the hues above.
    static let abyss = Color(hue: 0.60, saturation: 0.45, brightness: 0.055)
    static let abyssSoft = Color(hue: 0.60, saturation: 0.38, brightness: 0.12)

    /// Warm coral, kept deliberately scarce — the one warm note in a cool
    /// palette, so it reads as "look here" without needing extra size.
    static let accent = Color(hue: 0.03, saturation: 0.74, brightness: 0.96)
    static let accentSoft = Color(hue: 0.03, saturation: 0.30, brightness: 0.99)

    // MARK: Gradients

    /// The workhorse fill for primary buttons, badges and avatars: blue into
    /// green across the diagonal, so two elements of different sizes still
    /// look like they were cut from the same cloth.
    static let gradient = LinearGradient(
        colors: [primary, emerald],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// A cooler, deeper variant for large hero surfaces, where the lighter
    /// `gradient` would be too loud across a whole header.
    static let heroGradient = LinearGradient(
        colors: [primaryLight, primary, emeraldDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Blue → green → black, top to bottom. The signature full-bleed
    /// background used behind dark-mode screens and hero headers.
    static let auroraGradient = LinearGradient(
        stops: [
            .init(color: primaryDeep, location: 0.0),
            .init(color: primary.opacity(0.85), location: 0.22),
            .init(color: emeraldDeep, location: 0.52),
            .init(color: abyssSoft, location: 0.78),
            .init(color: abyss, location: 1.0)
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// A subtle tinted wash for light mode: the same two hues, at a fraction
    /// of the saturation, over a near-white ground. Keeps the brand present
    /// without fighting dark body text for contrast.
    static let auroraGradientLight = LinearGradient(
        stops: [
            .init(color: Color(hue: 0.556, saturation: 0.16, brightness: 0.99), location: 0.0),
            .init(color: Color(hue: 0.48, saturation: 0.10, brightness: 0.985), location: 0.45),
            .init(color: Color(hue: 0.42, saturation: 0.07, brightness: 0.975), location: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let successGradient = LinearGradient(
        colors: [emeraldLight, emerald],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: Elevation

    static let cardShadow = Color.black.opacity(0.08)

    /// Semantic status colors, tuned to sit alongside the blue/green brand
    /// instead of clashing system defaults (a raw system `.orange` reads harsh
    /// and disconnected next to this palette).
    static let warning = Color(hue: 0.09, saturation: 0.72, brightness: 0.94)
    static let danger = Color(hue: 0.985, saturation: 0.74, brightness: 0.90)
    /// "Good" state — deliberately the same emerald as the aurora's second
    /// pole, so success reads as part of the brand rather than a stock green.
    static let success = emerald
    static let inProgress = Color(hue: 0.72, saturation: 0.50, brightness: 0.78)
    static let neutral = Color(.systemGray)

    // Loyalty tier colors — a distinct family from status colors above
    // (achievement tiers, not urgency/state), tuned to the same saturation
    // level as the rest of the palette instead of raw system .orange/.yellow.
    static let bronzeTier = Color(hue: 0.07, saturation: 0.55, brightness: 0.72)
    static let silverTier = Color(hue: 0.58, saturation: 0.06, brightness: 0.72)
    static let goldTier = Color(hue: 0.12, saturation: 0.65, brightness: 0.88)

    // MARK: Motion
    //
    // Tuned against Apple's fluid-interfaces defaults and Emil Kowalski's
    // animation standards:
    //  - critically damped (no bounce) for anything fired many times/day
    //    (button presses, toggles) — bounce is earned, not default
    //  - a little bounce only for rare/occasional delight moments
    //    (entrances, celebrations), kept under ~400ms response
    //  - never `ease-in` on UI — it delays the moment users are watching most
    static let springQuick = Animation.spring(response: 0.24, dampingFraction: 1.0)
    static let springSoft = Animation.spring(response: 0.38, dampingFraction: 0.9)
    static let springMomentum = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let crossFade = Animation.easeOut(duration: 0.22)

    /// Stagger delay for the nth item in a list entrance, capped so a long
    /// list doesn't push its later rows into a slow, sluggish-feeling reveal.
    static func staggerDelay(_ index: Int) -> Double {
        Double(min(index, 5)) * 0.04
    }
}

// MARK: - Ambient aurora background
//
// The app's signature surface. Two soft radial "lights" (blue up top-leading,
// green lower-trailing) drift slowly over a base wash, which in dark mode
// falls away to near-black. The drift is deliberately very slow and very
// small: it should register as "this surface is alive" in peripheral vision,
// never as something moving that the eye wants to track while reading.
//
// It is purely decorative and sits behind content, so it is marked
// non-interactive — a decorative layer that eats taps is the classic cause of
// "I have to tap three times".

struct AuroraBackground: View {
    /// When true, the blue/green lights are stronger — for hero headers and
    /// sign-in, where the background *is* the content.
    var intensity: Double = 1.0
    var animated: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    private var isDark: Bool { colorScheme == .dark }

    private var baseFill: LinearGradient {
        isDark ? Theme.auroraGradient : Theme.auroraGradientLight
    }

    private var blueOpacity: Double {
        (isDark ? 0.55 : 0.28) * intensity
    }

    private var greenOpacity: Double {
        (isDark ? 0.45 : 0.24) * intensity
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            // Generous overscan: the lights are blurred heavily, and a blur
            // whose source stops at the edge leaves a visible soft seam.
            let blob = max(w, h) * 0.95

            ZStack {
                baseFill

                Circle()
                    .fill(Theme.primary.opacity(blueOpacity))
                    .frame(width: blob, height: blob)
                    .blur(radius: blob * 0.28)
                    .offset(x: -w * 0.32, y: drift ? -h * 0.34 : -h * 0.24)

                Circle()
                    .fill(Theme.emerald.opacity(greenOpacity))
                    .frame(width: blob * 0.9, height: blob * 0.9)
                    .blur(radius: blob * 0.26)
                    .offset(x: w * 0.36, y: drift ? h * 0.30 : h * 0.40)

                // In dark mode the bottom has to actually reach black, or the
                // green light bleeds all the way down and the screen reads as
                // uniformly murky instead of having a floor.
                if isDark {
                    LinearGradient(
                        colors: [.clear, Theme.abyss.opacity(0.75), Theme.abyss],
                        startPoint: .center, endPoint: .bottom
                    )
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

extension View {
    /// The standard screen ground. Replaces bare `Color(.systemGroupedBackground)`
    /// so every scroll view in the app sits on the same aurora instead of a
    /// flat system grey.
    func auroraScreenBackground(intensity: Double = 1.0) -> some View {
        self.background {
            AuroraBackground(intensity: intensity)
        }
    }
}

// MARK: - Typography
//
// Apple's type guidance is that tracking is size-specific, never one fixed
// value: large display text reads too loose at default tracking, body text
// reads cramped if you tighten it. The `brand*` fonts below are paired with
// the tracking helpers further down rather than baking one number in.

extension Font {
    static let brandLargeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let brandTitle = Font.system(.title2, design: .rounded, weight: .bold)
    static let brandTitle3 = Font.system(.title3, design: .rounded, weight: .semibold)
    static let brandHeadline = Font.system(.headline, design: .rounded, weight: .semibold)
    static let brandBody = Font.system(.body, design: .rounded)
    static let brandCallout = Font.system(.callout, design: .rounded)
    static let brandCaption = Font.system(.caption, design: .rounded, weight: .medium)
    static let brandCaption2 = Font.system(.caption2, design: .rounded, weight: .medium)

    /// Numerals that should line up in a column (prices, balances, counts).
    /// Proportional digits make a changing figure jitter horizontally.
    static func brandMono(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

extension View {
    /// Display-size text: tighten tracking as size grows.
    func brandDisplayText() -> some View {
        self.tracking(-0.6)
    }

    /// Small all-caps section eyebrows. Uppercase text needs *positive*
    /// tracking — caps have no ascender/descender variety to separate them,
    /// so at default tracking they clump into a block.
    func brandEyebrow() -> some View {
        self.font(.brandCaption2)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Press animation modifier — subtle scale + shadow lift on tap

struct PressableStyle: ButtonStyle {
    /// How far the label shrinks on press. Large surfaces need a smaller
    /// ratio than small ones to read as the same amount of "give".
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Without this, taps only register on the label's non-transparent
            // children (text/icons) — any Spacer() or background-only area in
            // a row's HStack/VStack silently ignores taps. Applying it here,
            // centrally, makes every row using this style tappable across its
            // whole visual bounds instead of only its intrinsic content.
            //
            // It is applied *after* the scale below deliberately: a
            // `contentShape` set before a transform is measured in the
            // pre-transform space, so a row caught mid-press would hit-test
            // against a rectangle that no longer matches what is on screen.
            .scaleEffect(configuration.isPressed ? scale : 1)
            .contentShape(Rectangle())
            .animation(Theme.springQuick, value: configuration.isPressed)
    }
}

extension View {
    /// Fades a view in — use on hero content and cards appearing on screen.
    ///
    /// Deliberately opacity-only. An entrance that also scales or offsets is
    /// prettier in a screenshot, but it moves the view's hit-test geometry for
    /// the length of the animation, and inside a `LazyVStack` that window
    /// reopens every time a row scrolls back into view. That is precisely the
    /// "I tapped it three times before it did anything" failure, and no
    /// entrance flourish is worth it. Depth and life come from the aurora,
    /// press feedback, and transitions instead.
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
            .onAppear {
                // Guard so a row recycled by a lazy container doesn't fade
                // out and back in every time it crosses the viewport edge.
                guard !isVisible else { return }
                if reduceMotion || delay == 0 {
                    withAnimation(Theme.crossFade) { isVisible = true }
                } else {
                    withAnimation(Theme.crossFade.delay(delay)) { isVisible = true }
                }
            }
    }
}

// MARK: - Selectable card — the shared "pick one of these" visual language.
// Apple-style selected state: a brand stroke, a subtle lift (stronger shadow),
// and a small checkmark badge overlapping the bottom-trailing corner — all
// driven by one spring so every picker in the app (packages, plans, payment
// methods, slots, variants, add-ons, filters) animates and looks identical
// instead of each screen inventing its own.
extension View {
    /// Wrap any card-shaped row/tile with this to get the standard selected
    /// look. `cornerRadius` should match the content's own background shape
    /// (pass the same radius used for the card behind `self`, if any) so the
    /// stroke and badge sit flush against it.
    func selectable(isSelected: Bool, cornerRadius: CGFloat = 14) -> some View {
        modifier(SelectableCardStyle(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

struct SelectableCardStyle: ViewModifier {
    let isSelected: Bool
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear),
                        lineWidth: 2
                    )
            )
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(Theme.gradient)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(.background, lineWidth: 2))
                .offset(x: 6, y: 6)
                .scaleEffect(isSelected ? 1 : 0.01)
                .opacity(isSelected ? 1 : 0)
                // Decorative: the tap target is the card itself, and a badge
                // that overhangs the corner must not steal taps from whatever
                // sits beside it.
                .allowsHitTesting(false)
            }
            // No scale on selection: a selected card that grows shifts the
            // hit-test geometry of every card after it in the stack, which
            // makes the *next* tap land on the wrong row. The stroke, badge
            // and shadow carry the state on their own.
            .shadow(
                color: isSelected ? Theme.primary.opacity(0.28) : Theme.cardShadow,
                radius: isSelected ? 16 : 6,
                y: isSelected ? 8 : 2
            )
            .animation(Theme.springSoft, value: isSelected)
    }
}

// MARK: - Shimmering loading placeholder (used while data streams in)

struct ShimmerView: View {
    var cornerRadius: CGFloat = 16
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.28), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width * 1.6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}
