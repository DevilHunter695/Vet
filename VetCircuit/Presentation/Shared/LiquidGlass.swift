import SwiftUI

// MARK: - Liquid glass
//
// This was hand-rolled — `.ultraThinMaterial` under a gradient face, a
// specular hairline and a rim stroke — because `glassEffect` needed iOS 26
// and the project targeted 17. It now targets 26, so the imitation is gone
// and the real material does the work.
//
// That deletes a lot more than the drawing code. The hand-rolled version had
// to reason about colour scheme, composite its own reduced-transparency
// fallback, and pick a shadow radius per surface size; the system material
// handles every one of those itself, and handles them better, because it can
// see what is actually behind the surface and we could only guess.
//
// `GlassLevel` stays, and is now a mapping rather than a set of magic
// numbers: it says what a surface *is* in this app's hierarchy — floating
// chrome, a card in the content, the one featured card on a screen — and
// turns that into the system variant that suits it. Apple's rule that a light
// translucent surface must never stack on another is still the reason the
// distinction exists.

enum GlassLevel {
    /// Floating chrome — toolbar buttons, the pinned checkout bar. The
    /// clearest of the three: this layer exists to let content pass beneath
    /// it, and it is always the topmost surface.
    case chrome
    /// A card in the content flow. Text sits directly on it and nothing
    /// floats above it, so it takes the standard material.
    case surface
    /// The one card on a screen that should read as the headline. Carries a
    /// brand tint; still glass, not a filled panel.
    case featured

    /// The system material this level maps to.
    ///
    /// `.clear` is the variant meant for chrome over content, `.regular` the
    /// standard surface. `interactive` is reserved for surfaces a finger
    /// actually lands on — it makes the material respond to touch, which is
    /// wrong for a card that is only being read.
    func glass(tint: Color? = nil, interactive: Bool = false) -> Glass {
        let base: Glass
        switch self {
        case .chrome: base = .clear
        case .surface: base = .regular
        case .featured: base = .regular
        }
        return base.tint(tint).interactive(interactive)
    }
}

struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let level: GlassLevel
    var tint: Color?
    /// Retained so existing call sites keep compiling. The system draws the
    /// material's own edge now, and it does it better than a hand-drawn
    /// stroke could — so this no longer has anything to set.
    var strokeWidth: CGFloat = 1
    /// True for small chips — an icon button, a control-group capsule — as
    /// opposed to a card-sized surface. The system varies the material by
    /// the shape it is given, so this now only decides whether the surface
    /// should respond to touch.
    var compact: Bool = false

    func body(content: Content) -> some View {
        content.glassEffect(level.glass(tint: tint, interactive: compact), in: shape)
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
}

extension View {
    /// No longer needed — the system tab bar handles its own safe area.
    func floatingTabBarScroll() -> some View { self }

    /// No longer needed — the system tab bar handles its own safe area.
    func floatingTabBarInset() -> some View { self }

    /// No longer needed — the bar tracks its own scrolling.
    func tracksScrollOffset() -> some View { self }
}

/// No longer needed — the bar tracks its own scrolling.
struct ScrollOffsetProbe: View {
    var body: some View { EmptyView() }
}
