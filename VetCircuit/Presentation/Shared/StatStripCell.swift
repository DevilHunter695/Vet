import SwiftUI

/// One figure in a `StatStrip`.
struct StatStripCell: View {
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
