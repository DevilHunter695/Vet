import SwiftUI
import UIKit

// MARK: - Small reusable component library — define once, reuse everywhere.
//
// Everything here follows three interaction rules, because the app's worst
// reported bug was taps that didn't register:
//
//  1. Every control's tap target is at least 44×44pt and covers its whole
//     visual bounds (an explicit `contentShape`, never relying on the label's
//     opaque pixels).
//  2. Decorative layers — glows, badges, shimmer, gradients — are marked
//     `allowsHitTesting(false)` so they can never sit in front of a control.
//  3. Press feedback is a transform on the *label*, applied by the button
//     style, so the hit region and the thing the user sees stay in sync.

// MARK: Buttons

/// The app's primary call to action: the blue→green brand gradient, a soft
/// coloured glow beneath it, and a loading state that keeps the button's size
/// fixed so the layout doesn't jump when it starts working.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            guard !isLoading, isEnabled else { return }
            Haptics.confirm()
            action()
        } label: {
            ZStack {
                // Keeps the intrinsic height identical between states, so
                // swapping in the spinner never reflows the screen.
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage).scaledIcon(16, weight: .semibold)
                    }
                    Text(title).font(.brandHeadline)
                }
                .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.vertical, 15)
            .padding(.horizontal, 20)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.gradient)
                    .overlay {
                        // A one-pixel light catch along the top edge. Real
                        // raised surfaces catch light on the edge facing it;
                        // without this the button reads as a flat sticker.
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                    .allowsHitTesting(false)
            }
            .shadow(color: Theme.primary.opacity(isEnabled ? 0.35 : 0), radius: 14, y: 7)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.975))
        .disabled(isLoading || !isEnabled)
        .opacity(isEnabled ? (isLoading ? 0.9 : 1) : 0.45)
        .animation(Theme.crossFade, value: isLoading)
        .animation(Theme.crossFade, value: isEnabled)
        .accessibilityLabel(title)
    }
}

/// The quieter sibling: same geometry and same tap target, but a translucent
/// surface with a brand-tinted label. Used for the second option in a pair, so
/// the two read as one decision rather than two competing CTAs.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    private var tint: Color { role == .destructive ? Theme.danger : Theme.primary }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).scaledIcon(16, weight: .semibold)
                }
                Text(title).font(.brandHeadline)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.vertical, 15)
            .padding(.horizontal, 20)
            .foregroundStyle(tint)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.975))
        .accessibilityLabel(title)
    }
}

/// A compact pill-shaped action for use inside cards and toolbars, where a
/// full-width button would be far too heavy. Still 44pt tall.
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.primary
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).scaledIcon(13, weight: .semibold)
                }
                Text(title).font(.brandCaption)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(filled ? AnyShapeStyle(Theme.onBrightFill) : AnyShapeStyle(tint))
            .background {
                Capsule()
                    .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)))
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(title)
    }
}

// MARK: Surfaces

/// A translucent "glass" surface tuned separately for light/dark. Naively
/// pairing `.ultraThinMaterial` with a fixed `.white.opacity(_)` stroke reads
/// fine in light mode but turns into a harsh bright ring floating in a dark
/// room once the system material darkens — real glass catches light on one
/// edge and fades into shadow on the other, and that highlight has to dim
/// with the surrounding material, not stay flat white.
extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: nil))
    }

    /// Glass with a faint brand wash through it — for the one card on a
    /// screen that should feel like the headline.
    func featuredGlassCard(cornerRadius: CGFloat = 20, tint: Color = Theme.primary) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

/// Kept as the app's card entry point, but the material now comes from
/// `LiquidGlass` so every surface in the app — cards, chrome, the tab bar,
/// toolbar buttons — is lit from the same direction and made of the same
/// stuff. Before this, cards drew their own flat white border while the new
/// chrome refracted at its rim, and two surfaces on the same screen looked
/// like they came from different apps.
private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        content.glassPanel(
            cornerRadius: cornerRadius,
            level: tint == nil ? .surface : .featured,
            tint: tint
        )
    }
}

struct Card<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .glassCard(cornerRadius: cornerRadius)
    }
}

// MARK: Structure

/// A section heading with an optional trailing action. Gives every screen the
/// same rhythm — eyebrow, title, action — instead of each one inventing its
/// own header weight and spacing.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .scaledIcon(14, weight: .semibold)
                    .foregroundStyle(Theme.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .typeTitle()
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .typeMeta()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    // Padding and frame live on the *label*: applied outside
                    // the Button they would only pad the surrounding layout,
                    // leaving the actual touch region the size of the text.
                    Text(actionTitle)
                        .font(.brandCaption)
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.94))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A label/value row — the workhorse of every detail screen. Right-aligned
/// value, monospaced digits when it's a figure, so a column of them lines up.
struct InfoRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var valueColor: Color? = nil
    var isMonospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .scaledIcon(13, weight: .regular)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, alignment: .leading)
            }
            Text(label)
                .font(.brandCallout)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(isMonospaced ? .brandMono(.callout) : .system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(valueColor ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A small, self-explaining tag. Used for species, languages, service types,
/// verification — anything where the value is a word rather than a number.
struct TagChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.primary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).scaledIcon(10, weight: .semibold)
            }
            Text(text).font(.brandCaption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

/// A short explanatory note with an icon — for the places where the app has to
/// tell the user *why* something is the way it is (a policy, a fee, a wait).
/// A prototype shows a number; a finished product explains it.
struct CalloutNote: View {
    let text: String
    var systemImage: String = "info.circle.fill"
    var tint: Color = Theme.primary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .scaledIcon(13, weight: .regular)
                .foregroundStyle(tint)
            Text(text)
                .font(.brandCaption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Status

struct StatusBadge: View {
    let status: Visit.VisitStatus

    private var color: Color {
        switch status {
        case .requested: return Theme.warning
        case .confirmed, .assigned: return Theme.primary
        case .enRoute, .arrived, .inProgress: return Theme.inProgress
        case .completed, .resolved: return Theme.success
        case .cancelledByUser, .cancelledByVet, .noShowUser, .noShowVet: return Theme.neutral
        case .disputed: return Theme.danger
        }
    }

    private var icon: String {
        switch status {
        case .requested: return "clock.fill"
        case .confirmed: return "checkmark.circle.fill"
        case .assigned: return "person.fill.checkmark"
        case .enRoute: return "figure.walk.motion"
        case .arrived: return "location.fill"
        case .inProgress: return "stethoscope"
        case .completed: return "checkmark.seal.fill"
        case .cancelledByUser, .cancelledByVet: return "xmark.circle.fill"
        case .noShowUser, .noShowVet: return "questionmark.circle.fill"
        case .disputed: return "exclamationmark.triangle.fill"
        case .resolved: return "checkmark.circle"
        }
    }

    /// Statuses where something is actively happening get a ring around the
    /// badge, so a glance at the list tells you which visit is live.
    private var isLive: Bool { status.isLive }

    var body: some View {
        Label(status.displayText, systemImage: icon)
            .font(.brandCaption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                ZStack {
                    Capsule().fill(color.opacity(0.16))
                    if isLive {
                        Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            }
            .foregroundStyle(color)
            .accessibilityLabel("Status: \(status.displayText)")
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            Group {
                if let attachmentURL = message.attachmentURL {
                    // J2: "Pet owners send photos. Always." — rendered inline,
                    // not as a bare filename link.
                    AsyncImage(url: attachmentURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(Theme.textSecondary)
                        default:
                            ShimmerView(cornerRadius: 18)
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(message.body)
                        .font(.brandBody)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isMine ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.ultraThinMaterial))
                                .allowsHitTesting(false)
                        }
                        .foregroundStyle(isMine ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: isMine ? Theme.primary.opacity(0.25) : .clear, radius: 8, y: 4)
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .transition(.asymmetric(insertion: .move(edge: isMine ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (isMine ? "You: " : "") + (message.attachmentURL != nil ? "Photo message" : message.body)
        )
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.primary.opacity(0.22))
                    .frame(width: 128, height: 128)
                    .blur(radius: 18)
                PawMascot(size: 72, animated: true)
            }
            .allowsHitTesting(false)

            Text(title)
                .font(.brandTitle3)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.brandCallout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                PillButton(title: actionTitle, tint: Theme.primary, filled: true, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.danger.opacity(0.3), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .foregroundStyle(Theme.danger)
            .accessibilityLabel("Error: \(message)")
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
