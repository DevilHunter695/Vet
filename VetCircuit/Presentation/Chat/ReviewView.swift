import SwiftUI
import UIKit
import StoreKit

@Observable
@MainActor
final class ReviewViewModel {
    let visitId: UUID
    var rating: Int = 5
    var comment: String = ""
    var isSubmitting = false
    var errorMessage: String?
    var didSubmit = false

    private let submitReviewUseCase = DependencyContainer.shared.submitReviewUseCase()
    private let loyaltyRepository = DependencyContainer.shared.loyaltyRepository

    init(visitId: UUID) { self.visitId = visitId }

    func submit(userId: UUID) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await submitReviewUseCase.execute(visitId: visitId, rating: rating, comment: comment.isEmpty ? nil : comment)
            // Reward loyalty points for completing the feedback loop.
            _ = try? await loyaltyRepository.awardPoints(userId: userId, points: 20)
            didSubmit = true
            if rating >= 4 { Haptics.success() } else { Haptics.tap() }
            if rating == 5 { requestAppStoreReviewIfDue() }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    /// N5: only after a 5★ visit — the moment a customer is happiest is the
    /// right moment to ask, and StoreKit's own throttling doesn't stop us
    /// from prompting on every single 5★ review, so gate it ourselves to
    /// once per app version (a reasonable judgment call, not an App Store rule).
    private func requestAppStoreReviewIfDue() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let key = "vc.review_prompt_shown_version"
        guard UserDefaults.standard.string(forKey: key) != currentVersion else { return }
        UserDefaults.standard.set(currentVersion, forKey: key)
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        SKStoreReviewController.requestReview(in: scene)
    }
}

struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var viewModel: ReviewViewModel

    init(visitId: UUID) { _viewModel = State(initialValue: ReviewViewModel(visitId: visitId)) }

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.didSubmit && viewModel.rating >= 4 {
                    ConfettiView()
                }

                VStack(spacing: 28) {
                    PawMascot(size: 64, animated: viewModel.rating >= 4)
                        .appearAnimation()

                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { star in
                            StarRatingButton(star: star, rating: viewModel.rating) {
                                withAnimation(Theme.springQuick) { viewModel.rating = star }
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rating")
                    .accessibilityValue("\(viewModel.rating) out of 5 stars")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: viewModel.rating = min(5, viewModel.rating + 1)
                        case .decrement: viewModel.rating = max(1, viewModel.rating - 1)
                        @unknown default: break
                        }
                    }

                    TextField("Leave a comment (optional)", text: $viewModel.comment, axis: .vertical)
                        .font(.brandBody)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .lineLimit(3...6)

                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    PrimaryButton(title: "Submit review", isLoading: viewModel.isSubmitting) {
                        Task { if let user = session.currentUser { await viewModel.submit(userId: user.id) } }
                    }
                }
                .padding()
                .disabled(viewModel.didSubmit)
            }
            .auroraScreenBackground()
            .navigationTitle("Rate your visit")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: viewModel.didSubmit) { _, submitted in
                guard submitted else { return }
                // Let the celebration play for a beat before dismissing.
                let delay = viewModel.rating >= 4 ? 1.1 : 0.3
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { dismiss() }
            }
        }
    }
}

private struct StarRatingButton: View {
    let star: Int
    let rating: Int
    let onTap: () -> Void

    private var isFilled: Bool { star <= rating }

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            Image(systemName: isFilled ? "star.fill" : "star")
                .font(.system(size: 34))
                .foregroundStyle(isFilled ? Color.yellow : Color(.tertiaryLabel))
                .scaleEffect(isFilled ? 1.08 : 1)
                .animation(Theme.springQuick, value: rating)
        }
        .buttonStyle(PressableStyle())
    }
}

#Preview {
    ReviewView(visitId: UUID()).environment(SessionStore())
}
