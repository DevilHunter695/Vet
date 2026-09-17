import Testing
import SwiftUI
import UIKit
@testable import VetCircuit

/// The readability claim, measured instead of asserted.
///
/// I rebalanced this app's palette and told the user contrast was "raised to
/// 4.5:1" — on the strength of having done the arithmetic once, by hand, in my
/// head, for a few pairings. That is the same kind of evidence that let twelve
/// features be "done" and inert: a claim nobody can check.
///
/// Contrast is not a matter of taste. WCAG 2.1 defines it exactly: the ratio
/// of relative luminances, (L1 + 0.05) / (L2 + 0.05), where L is computed from
/// linearised sRGB channels. So every colour pairing the app actually uses is
/// computed here and held to the real thresholds — 4.5:1 for body text, 3:1
/// for large text and for UI component boundaries.
///
/// This cannot tell anyone whether the app looks *good*. It can tell them the
/// text is legible, which is the part of "looks like a prototype" that has a
/// right answer.
@Suite("Colour contrast (WCAG 2.1)")
@MainActor
struct ContrastTests {

    /// WCAG's own formula, not an approximation. Each channel is linearised
    /// before weighting — the common mistake is averaging raw sRGB values,
    /// which overstates the contrast of mid-tones and is exactly how a palette
    /// passes on paper and fails on screen.
    private func relativeLuminance(_ color: Color, dark: Bool) -> Double {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)

        func linearise(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearise(r) + 0.7152 * linearise(g) + 0.0722 * linearise(b)
    }

    /// Composites `color` (which may be translucent) over `background` first,
    /// because contrast is a property of what is actually on screen. A 78%
    /// white over near-black is not white.
    private func flatten(_ color: Color, over background: Color, dark: Bool) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let top = UIColor(color).resolvedColor(with: traits)
        let bottom = UIColor(background).resolvedColor(with: traits)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(uiColor: UIColor(
            red: tr * ta + br * (1 - ta),
            green: tg * ta + bg * (1 - ta),
            blue: tb * ta + bb * (1 - ta),
            alpha: 1
        ))
    }

    private func ratio(_ foreground: Color, on background: Color, dark: Bool = true) -> Double {
        let composited = flatten(foreground, over: background, dark: dark)
        let l1 = relativeLuminance(composited, dark: dark)
        let l2 = relativeLuminance(background, dark: dark)
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The near-black the aurora resolves to across most of every screen. This
    /// is the background almost all body text is read against.
    private var ground: Color { Theme.abyss }

    // MARK: Body text — 4.5:1

    @Test("the three text tokens clear the body-text floor on the app's ground")
    func textTokensAreLegible() {
        for (name, color) in [("textPrimary", Theme.textPrimary),
                              ("textSecondary", Theme.textSecondary),
                              ("textTertiary", Theme.textTertiary)] {
            let measured = ratio(color, on: ground)
            #expect(measured >= 4.5,
                    "Theme.\(name) is \(String(format: "%.2f", measured)):1 on the app ground — below the 4.5:1 body-text floor")
        }
    }

    /// `primary` and `emerald` are used as *text*: prices, links, section
    /// icons, the figures on stat tiles. This is the pairing I actually
    /// changed, and the one worth locking down.
    @Test("the brand hues clear the body-text floor when used as text")
    func brandHuesAreLegibleAsText() {
        for (name, color) in [("primary", Theme.primary),
                              ("emerald", Theme.emerald),
                              ("primaryLight", Theme.primaryLight),
                              ("emeraldLight", Theme.emeraldLight)] {
            let measured = ratio(color, on: ground)
            #expect(measured >= 4.5,
                    "Theme.\(name) is \(String(format: "%.2f", measured)):1 as text on the app ground — below 4.5:1")
        }
    }

    @Test("status colours are legible as text, since that is how they are used")
    func statusColoursAreLegible() {
        for (name, color) in [("danger", Theme.danger), ("warning", Theme.warning),
                              ("success", Theme.success), ("inProgress", Theme.inProgress)] {
            let measured = ratio(color, on: ground)
            #expect(measured >= 4.5,
                    "Theme.\(name) is \(String(format: "%.2f", measured)):1 on the app ground — below 4.5:1")
        }
    }

    // MARK: Fills — the requirement runs the other way

    /// A fill and a foreground have opposite contrast requirements, which is
    /// why `fillBlue`/`fillGreen` exist separately from `primary`/`emerald`.
    /// White on the brightened brand hues would be about 2:1; this is the test
    /// that stops someone "simplifying" the two pairs back into one.
    @Test("white on the button fills clears the body-text floor")
    func whiteOnFillsIsLegible() {
        for (name, color) in [("fillBlue", Theme.fillBlue), ("fillGreen", Theme.fillGreen),
                              ("primaryDeep", Theme.primaryDeep), ("emeraldDeep", Theme.emeraldDeep)] {
            let measured = ratio(.white, on: color)
            #expect(measured >= 4.5,
                    "White on Theme.\(name) is \(String(format: "%.2f", measured)):1 — below 4.5:1")
        }
    }

    /// The counterpart: dark-on-bright for filled pills and selected chips.
    @Test("the on-bright-fill foreground is legible on the bright brand hues")
    func onBrightFillIsLegible() {
        for (name, color) in [("primary", Theme.primary), ("emerald", Theme.emerald)] {
            let measured = ratio(Theme.onBrightFill, on: color)
            #expect(measured >= 4.5,
                    "Theme.onBrightFill on Theme.\(name) is \(String(format: "%.2f", measured)):1 — below 4.5:1")
        }
    }

    // MARK: The regression this whole exercise was about

    /// The old aurora put a bright mid-blue behind the top third of every
    /// screen, and white body text on it measured roughly 2.5:1. The
    /// background is code, so that is checkable: the darkest stop the gradient
    /// starts from must still carry white text.
    @Test("white text is legible against the top of the aurora, not just its floor")
    func auroraTopIsLegible() {
        // The first stop of `auroraGradient` — the brightest point of the
        // background, at the very top of the screen, directly behind the
        // navigation title.
        let auroraTop = Color(hue: 0.585, saturation: 0.72, brightness: 0.22)
        let measured = ratio(Theme.textPrimary, on: auroraTop)
        // One interpolated literal, not a concatenation: Swift Testing's
        // message parameter is `Comment?`, which a string *literal* converts to
        // and a `String` expression does not. `"a" + "b"` is an expression.
        #expect(measured >= 4.5,
                "White text at the top of the aurora is \(String(format: "%.2f", measured)):1 — this is the regression that made the app look washed out")
    }

    /// The opposite regression from `auroraTopIsLegible`, and the one that
    /// made every card look like a flat grey rectangle: the aurora's floor
    /// was pushed all the way to opaque black, and a blurred material over
    /// pure black has no light to refract, so it resolves to plain grey. The
    /// floor has to stay dark enough for white text and bright enough to be
    /// glass — this pins both ends of that window.
    @Test("the aurora floor keeps enough light in it for glass to refract")
    func auroraFloorIsNotPureBlack() {
        // The last stop of `auroraGradient`, behind the bottom of every
        // scrolling screen — which is where most cards actually sit.
        let auroraFloor = Color(hue: 0.61, saturation: 0.40, brightness: 0.065)
        let luminance = relativeLuminance(auroraFloor, dark: true)
        #expect(luminance > 0.002,
                "The aurora floor has luminance \(String(format: "%.4f", luminance)) — it is effectively black again, and glass over it will read as a grey rectangle")

        let measured = ratio(Theme.textPrimary, on: auroraFloor)
        #expect(measured >= 4.5,
                "White text on the aurora floor is \(String(format: "%.2f", measured)):1 — the floor was brightened past what body text can sit on")
    }

    @Test("the ground really is near-black, not a mid-tone wash")
    func groundIsDark() {
        let luminance = relativeLuminance(ground, dark: true)
        #expect(luminance < 0.02,
                "Theme.abyss has luminance \(String(format: "%.4f", luminance)) — it is no longer a near-black floor")
    }
}
