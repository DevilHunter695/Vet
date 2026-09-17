import SwiftUI

// MARK: - Liquid glass
//
// Apple's own `glassEffect` needs iOS 26 and an Xcode 26 SDK; this project
// targets iOS 17 and builds on Xcode 16, so the material is hand-rolled. That
// is not purely a constraint — the system glass is deliberately conservative
// about opacity, and the brief here is "as transparent as you can", which
// needs control the API does not expose.
//
// What actually makes glass read as glass, rather than as a blurred rectangle:
//
//  1. **Refraction at the edge.** Real glass bends light at its rim, so the
//     boundary is brighter than the face. A single flat hairline border does
//     not do this — the highlight has to be strongest where light would hit
//     (top-leading) and fall away to nothing at the opposite edge.
//  2. **The face is barely there.** Most of the effect is blur plus edge. A
//     heavy fill turns glass into plastic. The fill here is 4–9% white.
//  3. **It sits above its background.** A shadow, and a dark under-layer that
//     keeps the blur from washing out over bright content.
//
// Apple's "never stack a light translucent surface on another" rule is why
// `GlassLevel` exists: chrome floating over content uses `.chrome`, a card
// sitting *in* content uses `.surface`, and nothing nests.

enum GlassLevel {
    /// Floating chrome — tab bar, toolbar buttons, the pinned checkout bar.
    /// The most transparent of the three: this layer is meant to let content
    /// pass under it, and it is always the topmost surface.
    case chrome
    /// A card in the content flow. Slightly more substantial, because text
    /// sits directly on it and it has no floating chrome above it.
    case surface
    /// The one card on a screen that should read as the headline. Carries a
    /// brand wash; still glass, not a filled panel.
    case featured

    var fillOpacity: Double {
        switch self {
        case .chrome: return 0.04
        case .surface: return 0.07
        case .featured: return 0.09
        }
    }

    /// How bright the refracted edge is at its strongest point.
    var edgeOpacity: Double {
        switch self {
        case .chrome: return 0.38
        case .surface: return 0.24
        case .featured: return 0.30
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .chrome: return 24
        case .surface: return 16
        case .featured: return 22
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .chrome: return 0.45
        case .surface: return 0.35
        case .featured: return 0.40
        }
    }
}

/// The edge highlight. Brightest at top-leading, gone by bottom-trailing —
/// one light source, consistently placed, which is what stops a screenful of
/// glass elements looking like unrelated stickers.
private struct GlassEdge: ShapeStyle {
    let opacity: Double
    let isDark: Bool

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(opacity), location: 0.0),
                .init(color: .white.opacity(opacity * 0.35), location: 0.35),
                .init(color: .white.opacity(opacity * 0.08), location: 0.7),
                .init(color: .white.opacity(isDark ? 0.02 : 0.10), location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let level: GlassLevel
    var tint: Color?
    var strokeWidth: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // Reduced transparency is not a suggestion: somebody who
                    // asked for it cannot read text over a live blur. Go
                    // nearly opaque and drop the material entirely.
                    if reduceTransparency {
                        shape.fill(isDark ? Color(white: 0.11) : Color(white: 0.97))
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.white.opacity(isDark ? level.fillOpacity : level.fillOpacity * 0.5))
                        if let tint {
                            shape.fill(
                                LinearGradient(
                                    colors: [tint.opacity(isDark ? 0.20 : 0.12), tint.opacity(0.0)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(
                        reduceTransparency
                            ? AnyShapeStyle(Color.primary.opacity(0.25))
                            : AnyShapeStyle(GlassEdge(opacity: level.edgeOpacity, isDark: isDark)),
                        lineWidth: strokeWidth
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(isDark ? level.shadowOpacity : level.shadowOpacity * 0.35),
                radius: level.shadowRadius,
                y: level.shadowRadius * 0.35
            )
    }
}

extension View {
    /// Glass in an arbitrary shape — use the capsule/rounded helpers below
    /// unless the shape is genuinely custom.
    func liquidGlass<S: InsettableShape>(
        _ shape: S, level: GlassLevel = .surface, tint: Color? = nil, strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(LiquidGlassModifier(shape: shape, level: level, tint: tint, strokeWidth: strokeWidth))
    }

    func glassCapsule(level: GlassLevel = .chrome, tint: Color? = nil) -> some View {
        liquidGlass(Capsule(style: .continuous), level: level, tint: tint)
    }

    /// The standard card. `cornerRadius` is continuous (a squircle) rather
    /// than circular, matching every rounded rectangle Apple draws.
    func glassPanel(cornerRadius: CGFloat = 22, level: GlassLevel = .surface, tint: Color? = nil) -> some View {
        liquidGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), level: level, tint: tint)
    }

    func glassCircle(level: GlassLevel = .chrome, tint: Color? = nil) -> some View {
        liquidGlass(Circle(), level: level, tint: tint)
    }
}

// MARK: - Scroll offset
//
// The floating chrome needs to know which way the content is moving. iOS 18's
// `onScrollGeometryChange` would do this in a line; on iOS 17 a preference key
// reading a pinned `GeometryReader` is the portable equivalent, and it costs
// one invisible view at the top of the scroll content.

struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Put this at the very top of a `ScrollView`'s content.
    func tracksScrollOffset(in space: String = "scroll") -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ScrollOffsetKey.self,
                    value: proxy.frame(in: .named(space)).minY
                )
            }
        }
    }
}

// MARK: - Living with floating chrome

enum FloatingChrome {
    /// How much room a scroll view must leave at the bottom so its last row
    /// can be read and tapped rather than sitting under the tab bar.
    ///
    /// Content scrolls *under* the bar by design — that is the point of a
    /// translucent floating layer — but the final item still has to come to
    /// rest somewhere clear of it.
    static let tabBarInset: CGFloat = 104
}

extension View {
    /// Everything a tab-root scroll view needs to cooperate with the floating
    /// bar: a named coordinate space for the offset reader, and enough bottom
    /// room that the last row is reachable.
    func floatingTabBarScroll() -> some View {
        coordinateSpace(name: "scroll")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: FloatingChrome.tabBarInset)
            }
    }
}

/// Put this as the first child of a tab root's scroll content. Zero height, no
/// layout effect — it exists only to report where the content currently sits.
struct ScrollOffsetProbe: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .tracksScrollOffset()
    }
}
