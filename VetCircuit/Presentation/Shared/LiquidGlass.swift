import SwiftUI

// MARK: - Surfaces
//
// Two materials, deliberately, because Apple's guidance draws a line between
// them that this app had blurred.
//
// Liquid Glass is the *functional* layer — bars, floating controls, the tab
// accessory — floating above content and letting it show through. Standard
// materials are for the content layer, giving cards structure without
// pretending to be chrome.
//
// The mistake worth recording: when the real `glassEffect` became available,
// every surface in the app was switched to it, cards included. That inverts
// what the material is for. Liquid Glass exists to separate controls from
// content; making the content out of it too removes the very distinction it
// was drawing, and the guidance says so twice — "don't use Liquid Glass in
// the content layer" and "use Liquid Glass effects sparingly… limit these
// effects to the most important functional elements".
//
// So `GlassLevel` is now a decision about *which layer a surface belongs to*,
// not how translucent it should be.

enum GlassLevel {
    /// Floating chrome — a pinned action bar, a toolbar button, the tab
    /// accessory. This is the functional layer that sits *above* content, and
    /// the only layer Liquid Glass belongs in.
    case chrome
    /// A card in the content flow. A standard material, not glass.
    case surface
    /// The one card on a screen that should read as the headline. Still a
    /// standard material; it earns its emphasis from a brand tint, not from
    /// being made of something different.
    case featured

    /// Whether this level is part of the floating functional layer.
    ///
    /// Apple's materials guidance draws a hard line here: "don't use Liquid
    /// Glass in the content layer… including it in the content layer can
    /// result in unnecessary complexity and a confusing visual hierarchy",
    /// and "use Liquid Glass effects sparingly… limit these effects to the
    /// most important functional elements".
    ///
    /// Applying it to every card — which is what this app did the moment the
    /// real material became available — inverts the point of the material.
    /// Liquid Glass exists to separate controls *from* content; making the
    /// content out of it too removes the distinction it was there to draw.
    var isFloatingChrome: Bool { self == .chrome }

    /// The Liquid Glass variant, for `.chrome` only.
    ///
    /// `.regular` rather than `.clear`: clear is for components over
    /// "visually rich backgrounds", and this app's ground is a broad gradient
    /// wash. Regular "blurs and adjusts the luminosity of background content
    /// to maintain legibility", which is what a bar full of labels needs.
    func glass(tint: Color? = nil, interactive: Bool = false) -> Glass {
        Glass.regular.tint(tint).interactive(interactive)
    }
}

struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let level: GlassLevel
    var tint: Color?
    /// Retained so existing call sites keep compiling. Both materials draw
    /// their own edge, and better than a hand-drawn stroke could.
    var strokeWidth: CGFloat = 1
    /// True for small chips, which is now only used to decide whether a
    /// floating surface should respond to touch.
    var compact: Bool = false

    func body(content: Content) -> some View {
        if level.isFloatingChrome {
            content.glassEffect(level.glass(tint: tint, interactive: compact), in: shape)
        } else {
            // Content layer: a standard material, which is what Apple points
            // at for "elements in the content layer", plus the brand wash
            // that makes a featured card the headline on its screen.
            content
                .background(.regularMaterial, in: shape)
                .background {
                    if let tint {
                        shape.fill(tint.opacity(0.14))
                    }
                }
        }
    }
}

extension View {
    /// Glass in an arbitrary shape — use the capsule/rounded helpers below
    /// unless the shape is genuinely custom.
    func liquidGlass<S: InsettableShape>(
        _ shape: S, level: GlassLevel = .surface, tint: Color? = nil, strokeWidth: CGFloat = 1, compact: Bool = false
    ) -> some View {
        modifier(LiquidGlassModifier(shape: shape, level: level, tint: tint, strokeWidth: strokeWidth, compact: compact))
    }

    /// `compact` defaults to true: a capsule is almost always a small
    /// control (a chip, a segmented group) rather than a card-sized
    /// surface, so it should carry the lighter, chip-weight shadow unless
    /// told otherwise.
    func glassCapsule(level: GlassLevel = .chrome, tint: Color? = nil, compact: Bool = true) -> some View {
        liquidGlass(Capsule(style: .continuous), level: level, tint: tint, compact: compact)
    }

    /// The standard card. `cornerRadius` is continuous (a squircle) rather
    /// than circular, matching every rounded rectangle Apple draws. Cards
    /// are the "bigger surface" end of the hierarchy, so this keeps the
    /// full-weight shadow.
    func glassPanel(cornerRadius: CGFloat = 22, level: GlassLevel = .surface, tint: Color? = nil) -> some View {
        liquidGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), level: level, tint: tint)
    }

    /// `compact` defaults to true for the same reason as `glassCapsule` —
    /// a glass circle is almost always an icon-sized control.
    func glassCircle(level: GlassLevel = .chrome, tint: Color? = nil, compact: Bool = true) -> some View {
        liquidGlass(Circle(), level: level, tint: tint, compact: compact)
    }
}

// MARK: - Floating chrome (retained as no-ops)
//
// The system tab bar reserves its own space and minimizes itself, so nothing
// here has work left to do. The modifiers stay, doing nothing, so the ~37
// screens that call them did not all have to be edited in the same change
// that swapped the bar — and so that swap stays reviewable.
//
// `ScrollOffsetProbe` likewise: it used to report a scroll view's offset up
// to the bar so the bar could decide whether to collapse. The bar decides
// that for itself now.

enum FloatingChrome {
    /// Nothing to reserve any more: the system bar participates in safe area
    /// on its own, so content can no longer come to rest underneath it.
    /// Kept at zero rather than deleted so the constant's callers still read.
    static let tabBarInset: CGFloat = 0

    /// Height of the tab bar's bottom accessory, plus a little breathing
    /// room. Deliberately modest: too much and every screen ends in a band of
    /// dead space, which is its own complaint.
    static let accessoryClearance: CGFloat = 56
}

extension View {
    /// No longer needed — the system tab bar handles its own safe area.
    func floatingTabBarScroll() -> some View { self }

    /// Clears the tab bar's bottom accessory.
    ///
    /// The system tab bar insets for itself, but `tabViewBottomAccessory` —
    /// the "Vet en route" pill — sits above it and its height is not added to
    /// the scroll content's safe area. So the last line of every screen was
    /// parked underneath it: on Profile, "Points still convert to wallet
    /// credit" was permanently half-hidden with no way to scroll it clear.
    ///
    /// `contentMargins` rather than `padding` on purpose: it moves the
    /// content without moving the scroll indicator, so the scrollbar still
    /// runs the true height of the view.
    func floatingTabBarInset() -> some View {
        contentMargins(.bottom, FloatingChrome.accessoryClearance, for: .scrollContent)
    }

    /// No longer needed — the bar tracks its own scrolling.
    func tracksScrollOffset() -> some View { self }
}

/// No longer needed — the bar tracks its own scrolling.
struct ScrollOffsetProbe: View {
    var body: some View { EmptyView() }
}
