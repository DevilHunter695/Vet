import CoreGraphics

/// The app's spacing scale.
///
/// Before this there was no scale. A sweep of the presentation layer found
/// padding values of 2, 4, 6, 8, 10, 12, 13, 14, 15, 16, 20 and 32 — a dozen
/// steps, several of them a point apart, chosen screen by screen. That is
/// why sibling screens never quite lined up: nothing was wrong anywhere in
/// particular, and nothing agreed with anything either.
///
/// Four-point steps, named for what they separate rather than for their
/// size, so a call site says what it means and the number stays reviewable:
///
///   hairline   2   inside a label, between a word and its own subtitle
///   tight      4   between two lines of one thought
///   snug       8   between rows of a group
///   row       12   inside a row, top and bottom
///   gutter    16   screen margins, inside a card
///   section   24   between one section and the next
///   major     32   around an empty state or a screen's one big moment
///
/// Anything that is not on this list needs a reason in a comment, not a
/// nudge until it looks right.
enum Spacing {
    static let hairline: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let row: CGFloat = 12
    static let gutter: CGFloat = 16
    static let section: CGFloat = 24
    static let major: CGFloat = 32

    /// The corner radius for a content surface — a card, a grouped row, a
    /// selection row. One value, so surfaces at different sizes still look
    /// like the same family. Chrome keeps the system's own radii.
    ///
    /// The same audit that found twelve spacing steps found eleven corner
    /// radii: 9, 10, 12, 14, 16, 18, 20, 24, 26, 28 and 30. Most of those
    /// are content surfaces that differ by two points for no reason, which
    /// is not a difference anybody sees as intentional — it just stops the
    /// screen from looking assembled by one person.
    static let corner: CGFloat = 18

    /// For things a finger does not treat as a surface: an icon badge, a
    /// chip, a small swatch. Kept separate because sweeping these up to the
    /// card radius would turn a 30pt icon tile into a blob.
    static let cornerSmall: CGFloat = 10
}
