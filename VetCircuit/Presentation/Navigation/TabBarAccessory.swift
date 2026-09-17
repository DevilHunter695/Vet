import SwiftUI

/// The thing a minimizing tab bar minimizes *around*.
///
/// Apple's tab bar guidance is specific about this: minimizing is described
/// "for tab bars with an attached accessory, like the MiniPlayer in Music" —
/// you shrink the bar and move the accessory inline with it as the person
/// scrolls down. A bar that shrinks with nothing to inline is just chrome
/// that disappears, which the same guidance warns against ("if you hide the
/// tab bar, people can forget which area of the app they're in").
///
/// This app's MiniPlayer equivalent is a visit that is actually happening:
/// a vet en route, arrived, or partway through. That is the one piece of
/// state a pet owner wants visible from every screen, and the one worth
/// keeping pinned above the tabs.
struct TabBarAccessoryModel: Equatable {
    let title: String
    let detail: String?
    let systemImage: String
    var tint: Color = Theme.inProgress
    /// Opens whatever the accessory is about. Not compared for equality —
    /// two accessories describing the same thing are the same accessory.
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.detail == rhs.detail
            && lhs.systemImage == rhs.systemImage && lhs.tint == rhs.tint
    }
}

/// The accessory, in whichever form the system is currently giving it room
/// for.
///
/// `tabViewBottomAccessoryPlacement` is `.expanded` while the tab bar is at
/// full size and `.inline` once it has minimized and the accessory has moved
/// in beside the tabs — the MiniPlayer transition, handed to us. Reading it
/// is what makes this an accessory rather than a strip that happens to sit
/// near the bar.
struct TabBarAccessory: View {
    let model: TabBarAccessoryModel

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        switch placement {
        case .inline:
            TabBarAccessoryInline(model: model)
        default:
            TabBarAccessoryStrip(model: model)
        }
    }
}

/// The accessory's full-width form, shown while the tab bar is at full size.
struct TabBarAccessoryStrip: View {
    let model: TabBarAccessoryModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: model.action) {
            HStack(spacing: 10) {
                LivePulse(tint: model.tint, isAnimating: !reduceMotion)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if let detail = model.detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the visit")
    }

    private var accessibilityLabel: String {
        [model.title, model.detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The accessory's minimized form: it rides inline with the tabs.
struct TabBarAccessoryInline: View {
    let model: TabBarAccessoryModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: model.action) {
            HStack(spacing: 7) {
                LivePulse(tint: model.tint, isAnimating: !reduceMotion)

                Text(model.detail ?? model.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(GlassPressStyle())
        .accessibilityLabel([model.title, model.detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The "this is live, right now" dot.
///
/// A slow pulse rather than a blink: it has to read as a heartbeat from the
/// corner of the eye without ever asking to be looked at. Suppressed entirely
/// under Reduce Motion, where a repeating animation is exactly what somebody
/// asked not to have.
struct LivePulse: View {
    let tint: Color
    var isAnimating: Bool = true

    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.28))
                .frame(width: 18, height: 18)
                .scaleEffect(expanded ? 1.0 : 0.55)
                .opacity(expanded ? 0.0 : 1.0)

            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .onAppear {
            guard isAnimating else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
    }
}
