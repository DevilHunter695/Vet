import SwiftUI
import UIKit

// MARK: - Small reusable component library — define once, reuse everywhere.

struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            Haptics.confirm()
            action()
        } label: {
            ZStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.brandHeadline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .background(Theme.gradient)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.primary.opacity(0.3), radius: 10, y: 5)
        .buttonStyle(PressableStyle())
        .disabled(isLoading)
        .opacity(isLoading ? 0.85 : 1)
        .accessibilityLabel(title)
    }
}

/// A translucent "glass" surface tuned separately for light/dark. Naively
/// pairing `.ultraThinMaterial` with a fixed `.white.opacity(_)` stroke reads
/// fine in light mode but turns into a harsh bright ring floating in a dark
/// room once the system material darkens — real glass catches light on one
/// edge and fades into shadow on the other, and that highlight has to dim
/// with the surrounding material, not stay flat white.
extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var borderGradient: LinearGradient {
        let top = colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.75)
        let bottom = colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.18)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderGradient, lineWidth: 1)
            )
            .shadow(
                color: colorScheme == .dark ? .black.opacity(0.45) : Theme.cardShadow,
                radius: colorScheme == .dark ? 18 : 14,
                y: colorScheme == .dark ? 8 : 6
            )
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.background)
                    .shadow(color: Theme.cardShadow, radius: 12, y: 4)
            )
    }
}

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

    var body: some View {
        Label(status.displayText, systemImage: icon)
            .font(.brandCaption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
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
                            Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(message.body)
                        .font(.brandBody)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(isMine ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color(.secondarySystemBackground)))
                        .foregroundStyle(isMine ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .transition(.asymmetric(insertion: .move(edge: isMine ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
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
            PawMascot(size: 72, animated: true)
                .opacity(0.9)
            Text(title).font(.brandHeadline)
            Text(message)
                .font(.brandBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.brandHeadline)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.accentSoft)
                    .foregroundStyle(Theme.accent)
                    .clipShape(Capsule())
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .padding(10)
            .background(Theme.danger.opacity(0.12))
            .foregroundStyle(Theme.danger)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Error: \(message)")
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
