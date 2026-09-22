import SwiftUI

/// A row of summary figures in one glass surface, divided by hairlines.
///
/// This replaces a 2×2 grid of `StatTile`s. Four separate cards of identical
/// width, radius and height, stacked directly under a card of identical width
/// and radius, is what makes a screen read as one grey texture however good
/// the material is — the eye gets no rhythm to hold on to. One wide, shallow
/// surface with internal divisions reads as a different *kind* of thing from
/// the cards around it, which is the point.
struct StatStrip: View {
    struct Item: Identifiable {
        /// The label, not a fresh `UUID()`. A UUID minted in the initialiser
        /// is a new identity on every body evaluation, so SwiftUI tears every
        /// cell down and rebuilds it whenever any figure changes — and no
        /// value can ever animate, because nothing persists to animate from.
        var id: String { label }
        let value: String
        let label: String
        let systemImage: String
        var tint: Color = Theme.primary
        /// What VoiceOver reads, when the visible label has to be shorter
        /// than the thing it names. Four figures share one row here, so
        /// "Visits" earns its place on screen while "Visits done" is what
        /// actually describes the number — the abbreviation is a layout
        /// compromise and should not reach assistive tech.
        var accessibilityName: String?
    }

    let items: [Item]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Four figures squeezed into one row is what breaks at
                // accessibility sizes — `minimumScaleFactor` alone would
                // still end up shrinking the numbers to the point of
                // illegibility. A two-column grid gives each figure enough
                // width to actually set its type at, at the cost of the
                // single-row look this strip otherwise has.
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 16
                ) {
                    ForEach(items) { item in
                        StatStripCell(item: item)
                    }
                }
                .padding(.vertical, Spacing.gutter)
                .padding(.horizontal, Spacing.snug)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            // A seam within one pane, not a rule chopping the
                            // strip into separate boxes — see `GlassSeam`.
                            GlassSeam(axis: .vertical, inset: 10)
                        }

                        StatStripCell(item: item)
                    }
                }
                .padding(.vertical, Spacing.gutter)
            }
        }
        .glassCard(cornerRadius: Spacing.corner)
    }
}
