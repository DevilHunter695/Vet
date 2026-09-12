import SwiftUI

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

    init(visitId: UUID) { self.visitId = visitId }

    func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await submitReviewUseCase.execute(visitId: visitId, rating: rating, comment: comment.isEmpty ? nil : comment)
            didSubmit = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ReviewViewModel

    init(visitId: UUID) { _viewModel = State(initialValue: ReviewViewModel(visitId: visitId)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= viewModel.rating ? "star.fill" : "star")
                            .font(.system(size: 32))
                            .foregroundStyle(.yellow)
                            .onTapGesture { viewModel.rating = star }
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
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                PrimaryButton(title: "Submit review", isLoading: viewModel.isSubmitting) {
                    Task { await viewModel.submit() }
                }
            }
            .padding()
            .navigationTitle("Rate your visit")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: viewModel.didSubmit) { _, submitted in
                if submitted { dismiss() }
            }
        }
    }
}

#Preview {
    ReviewView(visitId: UUID())
}
