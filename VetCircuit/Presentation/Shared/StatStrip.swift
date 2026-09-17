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
        let id = UUID()
        let value: String
        let label: String
        let systemImage: String
        var tint: Color = Theme.primary
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    // A hairline that fades at both ends, so the division
                    // reads as a seam in one surface rather than a hard rule
                    // chopping it into separate boxes.
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0), location: 0.0),
                            .init(color: .white.opacity(0.16), location: 0.5),
                            .init(color: .white.opacity(0.0), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(width: 1)
                    .padding(.vertical, 10)
                }

                StatStripCell(item: item)
            }
        }
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 22)
    }
}

/// One figure in a `StatStrip`.
private struct StatStripCell: View {
    let item: StatStrip.Item

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(height: 18)

            Text(item.value)
                .font(.brandMono(.callout, weight: .bold))
                .foregroundStyle(.primary)
                .brandDisplayText()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(item.label)
                .font(.brandCaption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label): \(item.value)")
    }
}
