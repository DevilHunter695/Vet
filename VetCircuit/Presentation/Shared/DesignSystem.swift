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
        case .requested: return .orange
        case .confirmed: return Theme.primary
        case .enRoute: return .purple
        case .completed: return .green
        case .cancelled: return .gray
        }
    }

    private var icon: String {
        switch status {
        case .requested: return "clock.fill"
        case .confirmed: return "checkmark.circle.fill"
        case .enRoute: return "figure.walk.motion"
        case .completed: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle.fill"
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
            Text(message.body)
                .font(.brandBody)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(isMine ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color(.secondarySystemBackground)))
                .foregroundStyle(isMine ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Error: \(message)")
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
