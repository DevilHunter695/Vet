import SwiftUI

/// An SF Symbol sized in points that still grows with the text size.
///
/// `.font(.system(size: 21))` pins a symbol at 21pt forever. Apple's guidance
/// is the opposite: "increase the size of meaningful interface icons as font
/// size increases" — an icon that carries information has to stay legible for
/// the person who turned text up, and an icon frozen beside text that has
/// doubled looks broken as well as being hard to see.
///
/// Text styles scale on their own, so this is only for the cases where a
/// specific point size is genuinely wanted — a glyph that has to line up with
/// a particular row height or sit in a fixed circle. `@ScaledMetric` gives
/// that size the same scaling curve the body text style has, so the two move
/// together.
private struct ScaledIconModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

extension View {
    /// Sizes a symbol in points, scaled with the body text style.
    ///
    /// Prefer a plain text style (`.font(.title3)`) where the exact size does
    /// not matter — this is for the cases where it does.
    func scaledIcon(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        modifier(ScaledIconModifier(size: size, weight: weight))
    }
}
