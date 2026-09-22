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
    ///
    /// Brightness was raised from 0.62: a mid-brightness blue used as *text*
    /// (which is most of what `primary` does — prices, links, section icons)
    /// on a near-black ground lands around 3.5:1, under the 4.5:1 body-text
    /// floor. At 0.78 it clears it with room to spare and still reads as the
    /// same hue. Use `primaryDeep` where the colour is a *fill* behind white
    /// text, where the contrast requirement runs the other way.
    static let primary = Color(hue: 0.556, saturation: 0.62, brightness: 0.86)
    static let primaryLight = Color(hue: 0.545, saturation: 0.42, brightness: 0.95)
    static let primaryDeep = Color(hue: 0.585, saturation: 0.85, brightness: 0.42)

    /// Emerald — the second pole of the aurora. Used for "good" states,
    /// savings, credits, and anything that should read as healthy. Lifted for
    /// the same contrast reason as `primary`.
    static let emerald = Color(hue: 0.425, saturation: 0.60, brightness: 0.82)
    static let emeraldLight = Color(hue: 0.415, saturation: 0.42, brightness: 0.93)
    static let emeraldDeep = Color(hue: 0.445, saturation: 0.80, brightness: 0.38)

    // MARK: Text
    //
    // SwiftUI's `.primary`/`.secondary`/`.tertiary` are tuned for a flat
    // system background. Over the aurora — which carries its own colour and
    // luminance — `.secondary` (≈60% white in dark mode) drops most caption
    // text under 4.5:1, and `.tertiary` (≈30%) is close to invisible. These
    // tokens are the same three roles pinned to values that survive the
    // background they actually sit on.
    /// Adaptive so the light appearance (still a supported option in
    /// Settings) doesn't end up with white text on a near-white wash.
    // These respond to Increase Contrast as well as to dark mode.
    //
    // Apple's colour guidance asks for "an increased contrast option for each
    // variant that provides a significantly higher amount of visual
    // differentiation". Without it the setting does nothing here, which is a
    // strange thing for an app to do to the one group of people who went
    // looking for it: secondary text stayed at 78% and tertiary at 58%
    // however hard someone asked for more separation.
    //
    // The high-contrast steps are deliberately large rather than token. The
    // point of the setting is that the difference is obvious.
    static let textPrimary = Color(uiColor: UIColor { trait in
        let boost = trait.accessibilityContrast == .high
        return trait.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(white: boost ? 0 : 0.07, alpha: 1)
    })
    static let textSecondary = Color(uiColor: UIColor { trait in
        let boost = trait.accessibilityContrast == .high
        return trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: boost ? 0.95 : 0.78)
            : UIColor(white: 0, alpha: boost ? 0.90 : 0.68)
    })
    /// Light mode was 0.50 alpha, which over white is 3.98:1 — under the
    /// 4.5:1 floor WCAG sets for body text, and it is used for timestamps,
    /// captions and helper lines that people do have to read. 0.60 clears it
    /// at 5.74:1 and still reads as a third step below secondary.
    static let textTertiary = Color(uiColor: UIColor { trait in
        let boost = trait.accessibilityContrast == .high
        return trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: boost ? 0.85 : 0.62)
            : UIColor(white: 0, alpha: boost ? 0.82 : 0.60)
    })

    /// The floor the aurora falls away to. Not pure black — a hair of blue
    /// keeps it from looking like a dead pixel field next to the hues above.
    ///
    /// Lifted from 0.055. At that brightness this is black for practical
    /// purposes, which is why the empty screens in the screenshots read as
    /// black bands with a glow floating in them rather than as one surface.
    /// A little more light keeps the gradient continuous top to bottom.
    static let abyss = Color(hue: 0.60, saturation: 0.42, brightness: 0.095)
    static let abyssSoft = Color(hue: 0.60, saturation: 0.36, brightness: 0.155)

    /// Folded into the brand tint.
    ///
    /// This was a warm coral, described as "kept deliberately scarce". It was
    /// not scarce: it tinted lab reports, vials, catalog icons and a dozen
    /// other things that have no warm meaning, so a screen could show a
    /// coral icon, a purple one, a blue one and a red one in four consecutive
    /// rows with none of those colours saying anything.
    ///
    /// Red now means one thing in this app - destructive or wrong - and the
    /// brand tint carries everything decorative. The names stay so the call
    /// sites do not all have to change; the colour is what changed.
    static let accent = primary
    static let accentSoft = primaryLight

    // MARK: Gradients

    /// The workhorse fill for primary buttons, badges and avatars: blue into
    /// green across the diagonal, so two elements of different sizes still
    /// look like they were cut from the same cloth.
    ///
    /// Note these are *not* `primary`/`emerald`. Those two were brightened so
    /// they'd clear 4.5:1 as text on a dark ground — which makes them far too
    /// light to put white text *on top of*. A fill and a foreground have
    /// opposite contrast requirements, so the button fill keeps its own,
    /// deeper pair: white on these clears 4.5:1 in both appearances.
    /// The foreground to use on top of a *bright* brand fill (a filled pill,
    /// a selected chip). White on `primary`/`emerald` at their new brightness
    /// is roughly 2:1; the near-black ground colour on them is over 9:1.
    static let onBrightFill = Color(hue: 0.60, saturation: 0.55, brightness: 0.07)

    static let fillBlue = Color(hue: 0.578, saturation: 0.80, brightness: 0.58)
    static let fillGreen = Color(hue: 0.440, saturation: 0.76, brightness: 0.50)

    static let gradient = LinearGradient(
        colors: [fillBlue, fillGreen],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// A cooler, deeper variant for large hero surfaces, where the lighter
    /// `gradient` would be too loud across a whole header.
    static let heroGradient = LinearGradient(
        colors: [fillBlue, primaryDeep, emeraldDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Blue → green → black, top to bottom. The signature full-bleed
    /// background used behind dark-mode screens and hero headers.
    ///
    /// Rebalanced hard, and this is the single biggest readability change in
    /// the app. The previous stops put `primaryDeep` at the very top and a
    /// near-full-strength `primary` at 22% — i.e. the top third of every
    /// screen was a bright mid-blue, and every screen's most important text
    /// (the navigation title, the hero card, the first row of any list) was
    /// white-on-mid-blue. That is somewhere around 2.5:1: technically visible,
    /// genuinely hard to read, and the reason the whole app looked washed out.
    ///
    /// The fix is the one every dark interface that reads well makes: the
    /// ground is near-black effectively everywhere, and the blue and green
    /// survive as a *glow* — deepest at the very top edge, gone by a third of
    /// the way down. Colour still carries the brand, but it does it behind
    /// nothing that has to be read.
    static let auroraGradient = LinearGradient(
        stops: [
            .init(color: Color(hue: 0.585, saturation: 0.72, brightness: 0.22), location: 0.0),
            .init(color: Color(hue: 0.575, saturation: 0.64, brightness: 0.15), location: 0.18),
            .init(color: abyssSoft, location: 0.48),
            // Never reaches pure black. A card made of blur has nothing to
            // refract over flat #000 — it just resolves to grey. The floor
            // keeps a little blue in it so the glass has light to bend.
            .init(color: Color(hue: 0.60, saturation: 0.45, brightness: 0.085), location: 0.78),
            .init(color: Color(hue: 0.61, saturation: 0.40, brightness: 0.065), location: 1.0)
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// A whisper of brand over white for light mode.
    ///
    /// This used to run up to 0.16 saturation, which reads as mint rather
    /// than as white — so light mode looked like a different app from dark
    /// mode rather than the same app in a different appearance, and every
    /// white card on top of it sat there as a hard bright rectangle.
    ///
    /// The ground's job in light mode is to stay out of the way: the brand
    /// is carried by the cards, the accents and the gradient buttons, all of
    /// which are already doing it. A background that competes with them is
    /// the thing making the screen feel unresolved.
    static let auroraGradientLight = LinearGradient(
        stops: [
            .init(color: Color(hue: 0.556, saturation: 0.045, brightness: 1.0), location: 0.0),
            .init(color: Color(hue: 0.50, saturation: 0.030, brightness: 0.995), location: 0.45),
            .init(color: Color(hue: 0.42, saturation: 0.022, brightness: 0.99), location: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let successGradient = LinearGradient(
        colors: [fillGreen, emeraldDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: Spacing
    //
    // One scale, so the app has a rhythm rather than a collection of
    // individually reasonable numbers. Apple's layout guidance is that
    // alignment and consistent grouping are what let people scan a screen —
    // "people assume that aligned items are related to each other" — and a
    // stack spaced 3 next to one spaced 5 next to one spaced 9 quietly denies
    // them that signal.
    //
    // A 4pt grid with two half-steps for the places where 4 is genuinely too
    // much: the gap between a title and the caption directly under it, and
    // the inside of a small chip.
    enum Space {
        /// Between a label and the line that belongs to it.
        static let hairline: CGFloat = 2
        /// Inside a chip or badge.
        static let tight: CGFloat = 4
        /// Between closely related lines in a stack.
        static let snug: CGFloat = 6
        /// The default gap between elements in a group.
        static let regular: CGFloat = 8
        /// Between groups inside a card.
        static let comfortable: CGFloat = 12
        /// A card's inner padding, and the gap between cards.
        static let card: CGFloat = 16
        /// Between sections of a screen.
        static let section: CGFloat = 20
        /// Around a screen's most prominent block.
        static let generous: CGFloat = 28
    }

    // MARK: Elevation

    static let cardShadow = Color.black.opacity(0.08)

    /// Semantic status colors, tuned to sit alongside the blue/green brand
    /// instead of clashing system defaults (a raw system `.orange` reads harsh
    /// and disconnected next to this palette).
    static let warning = Color(hue: 0.09, saturation: 0.72, brightness: 0.94)
    /// Brightened and desaturated slightly when the ground was lifted.
    /// At the old values it measured 4.55:1 against the new ground - over
    /// the 4.5:1 floor, but by 0.05, which is not a margin. 5.37:1 is.
    static let danger = Color(hue: 0.985, saturation: 0.68, brightness: 0.95)
    /// "Good" state — deliberately the same emerald as the aurora's second
    /// pole, so success reads as part of the brand rather than a stock green.
    static let success = emerald
    /// "In progress" - a vet on the way, a visit under way.
    ///
    /// This was purple (hue 0.72), which is not a status colour in this
    /// palette or in Apple's. It sat next to the blue and the green and the
    /// red and added a fourth hue that meant nothing, which is most of why
    /// the visit screen read as noisy.
    ///
    /// In-progress is the app's own active state, so it takes the brand
    /// tint. Brightness stays at 0.85 because ContrastTests holds this to
    /// 4.5:1 on the app ground - it is a status *label* ("Vet en route"),
    /// so it is body text and has to clear the body-text floor.
    ///
    /// Correcting my own change: folding this into the brand tint removed
    /// the purple, which was right, but left it at the same hue and
    /// brightness as Theme.primary - and primary is what `confirmed` uses.
    /// So "confirmed" and "vet en route" became the same colour, and the
    /// difference between a booking that is settled and one that is
    /// happening right now is worth seeing at a glance.
    ///
    /// Still the brand family, no new hue: a brighter, more saturated cyan
    /// end of it. An active state should read as more alive than a settled
    /// one, which is hierarchy rather than decoration. 13.7:1 on the ground,
    /// against primary's 7.5:1.
    static let inProgress = Color(hue: 0.50, saturation: 0.70, brightness: 0.95)
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

    // Kept deliberately faint. These blobs sit *behind live text*, so every
    // point of opacity here is contrast taken away from whatever is on top of
    // them. They are there to stop the ground looking like flat black paint,
    // not to be seen in their own right.
    private var blueOpacity: Double {
        (isDark ? 0.34 : 0.20) * intensity
    }

    private var greenOpacity: Double {
        (isDark ? 0.28 : 0.16) * intensity
    }

    /// A third light, low and off-centre. Two lights at the top corners leave
    /// the bottom two-thirds of every screen in flat dark — which is exactly
    /// where most cards sit, and exactly why they read as grey rectangles.
    private var deepOpacity: Double {
        (isDark ? 0.24 : 0.10) * intensity
    }

    var body: some View {
        // Under the UI test runner this draws the base fill and nothing else.
        //
        // The lights below are three circles the size of the screen, each
        // with a gaussian blur of roughly a quarter of that. On a device
        // that is a GPU pass nobody notices. A CI simulator renders it in
        // software, on every screen in the app, and the main thread never
        // gets an idle moment - which is what
        // "process main thread busy for 30.0s" is.
        //
        // Same reasoning as AppMotion for the animations: the walkthrough
        // suite is testing that screens are reachable, not what they look
        // like, and it cannot test either if the app will not answer. What
        // ships is unchanged.
        if AppMotion.isUITesting {
            baseFill.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        } else {
            lights
        }
    }

    private var lights: some View {
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
                    .offset(x: w * 0.36, y: drift ? h * 0.16 : h * 0.26)

                Circle()
                    .fill(Theme.primary.opacity(deepOpacity))
                    .frame(width: blob * 0.85, height: blob * 0.85)
                    .blur(radius: blob * 0.30)
                    .offset(x: drift ? -w * 0.18 : -w * 0.30, y: h * 0.62)

                // The floor. It used to reach opaque black by 60% of the
                // height, which flattened every card below the fold — glass
                // over #000 is just grey. It now only damps the lights so
                // text keeps its contrast, and stops well short of opaque.
                if isDark {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Theme.abyss.opacity(0.22), location: 0.38),
                            .init(color: Theme.abyss.opacity(0.42), location: 0.72),
                            .init(color: Theme.abyss.opacity(0.52), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard animated, !AppMotion.loopsDisabled(reduceMotion: reduceMotion) else { return }
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
    /// Kept as `.caption` rather than the true `.caption2` text style: at
    /// caption2's ~11pt the type is below what Apple's HIG recommends for
    /// legible UI text, and Dynamic Type scales it into near-illegibility at
    /// larger accessibility sizes. The name is unchanged (many call sites
    /// reference it), only the underlying style is bumped up one step.
    static let brandCaption2 = Font.system(.caption, design: .rounded, weight: .medium)

    /// Numerals that should line up in a column (prices, balances, counts).
    /// Proportional digits make a changing figure jitter horizontally.
    static func brandMono(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

extension View {
    /// Retained as a no-op.
    ///
    /// This used to tighten tracking by hand. Apple's typography guidance is
    /// that "in a running app, the system font dynamically adjusts tracking
    /// at every point size" — the tightening large text needs is already
    /// applied. Doing it again on top cramped letters, and cramped them worst
    /// at the accessibility sizes where legibility matters most. Kept so the
    /// call sites read the same and did not all have to change.
    func brandDisplayText() -> some View { self }

    /// Screen titles that still live in a navigation bar rather than in the
    /// content. Kept so the two kinds of title agree on tracking even while
    /// some screens have been converted to `LargeTitle` and some have not.
    func brandNavTitleText() -> some View { self }

    /// Small all-caps section eyebrows. Uppercase text needs *positive*
    /// tracking — caps have no ascender/descender variety to separate them,
    /// so at default tracking they clump into a block.
    func brandEyebrow() -> some View {
        self.typeEyebrow()
            .foregroundStyle(Theme.textTertiary)
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
                        .scaledIcon(10, weight: .bold)
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
        .accessibilityHidden(true)
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
        .accessibilityHidden(true)
            .onAppear {
                guard !AppMotion.loopsDisabled(reduceMotion: reduceMotion) else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

// MARK: - The type scale
//
// Apple's rule is that tracking and leading are *size-specific*: large display
// text reads too loose at default tracking, small text reads cramped without a
// little extra. A single `letter-spacing` applied everywhere is wrong
// somewhere — and at display sizes the wrongness is plainly visible.
//
// SwiftUI has no way to bake tracking into a `Font`, so the scale has to be
// modifiers that set size, weight, tracking and leading together. Each role
// below is one decision, made once, instead of three decisions repeated at
// every call site and drifting apart.
//
// Hierarchy is built from weight and size *as a set*, not size alone —
// emphasis via weight adds presence without taking more room, which matters
// on a phone.

extension View {
    /// Screen titles.
    ///
    /// A text style rather than a fixed 34pt: at a fixed size the title was
    /// the one piece of text on a screen that ignored Dynamic Type entirely,
    /// so turning text up grew every label around it and left the heading
    /// behind. Tracking is the system's to set — see `brandDisplayText`.
    func typeDisplay() -> some View {
        font(.system(.largeTitle, design: .rounded, weight: .bold))
    }

    /// Section titles inside a screen.
    func typeTitle() -> some View {
        font(.system(.title3, design: .rounded, weight: .semibold))
    }

    /// The name of a thing in a row — the line the eye lands on first.
    func typeRowTitle() -> some View {
        font(.system(.body, design: .rounded, weight: .semibold))
    }

    /// Body copy. Tracking at zero, leading opened up: this is the only text
    /// somebody reads in sentences rather than scans, and it is the one place
    /// extra line spacing pays for the height it costs.
    func typeBody() -> some View {
        font(.system(.callout, design: .rounded))
            .lineSpacing(2)
    }

    /// The supporting line under a row title. Small text wants a touch more
    /// relative leading than body copy, the same size/leading inverse
    /// relationship as the tracking rule above — without it, wrapped two-line
    /// captions feel cramped against the row title sitting above them.
    func typeMeta() -> some View {
        font(.system(.footnote, design: .rounded))
            .lineSpacing(1)
    }

    /// Small all-caps labels. Caps have no ascender/descender variety to
    /// separate them, so at default tracking they clump into a block —
    /// positive tracking is not decoration here, it is legibility.
    ///
    /// Uses `.caption`, not `.caption2`: caption2 is the smallest text style
    /// system-wide and reads as illegible fine print, especially once
    /// uppercased (uppercasing already removes the ascender/descender shapes
    /// that help small text stay readable). Leading opened slightly too —
    /// the smaller the text, the more relative line spacing it needs to
    /// avoid feeling cramped, the inverse of the display-size rule above.
    func typeEyebrow() -> some View {
        font(.system(.caption, design: .rounded, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.9)
            .lineSpacing(1)
    }
}
