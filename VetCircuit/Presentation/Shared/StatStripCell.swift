import SwiftUI

/// One figure in a `StatStrip`.
struct StatStripCell: View {
    let item: StatStrip.Item

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: item.systemImage)
                .scaledIcon(15, weight: .semibold)
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
                .multilineTextAlignment(.center)
                // `StatStrip` reflows into two columns at accessibility
                // sizes, which gives the label room to wrap instead of
                // needing to be shrunk into unreadability.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.accessibilityName ?? item.label): \(item.value)")
    }
}
