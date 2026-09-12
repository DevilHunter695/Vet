import Foundation

/// Central composition root. Swap mock repositories for Supabase-backed ones
/// once `SUPABASE_URL` / `SUPABASE_ANON_KEY` are configured (see Resources/Config.swift).
@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    let authRepository: AuthRepository
    let circuitRepository: CircuitRepository
    let visitRepository: VisitRepository
    let subscriptionRepository: SubscriptionRepository
    let paymentRepository: PaymentRepository
    let chatRepository: ChatRepository
    let reviewRepository: ReviewRepository
    let petRepository: PetRepository
    let pushTokenRepository: PushTokenRepository

    private init() {
        // TODO: once Supabase package + Config.plist are added, branch here:
        // if AppConfig.isBackendConfigured { use Supabase*Repository } else { use Mock*Repository }
        self.authRepository = MockAuthRepository()
        self.circuitRepository = MockCircuitRepository()
        self.visitRepository = MockVisitRepository()
        self.subscriptionRepository = MockSubscriptionRepository()
        self.paymentRepository = MockPaymentRepository()
        self.chatRepository = MockChatRepository()
        self.reviewRepository = MockReviewRepository()
        self.petRepository = MockPetRepository()
        self.pushTokenRepository = MockPushTokenRepository()
    }

    // MARK: Use case factories

    func getCircuitsUseCase() -> GetCircuitsUseCase { GetCircuitsUseCase(repository: circuitRepository) }
    func bookVisitUseCase() -> BookVisitUseCase { BookVisitUseCase(visitRepository: visitRepository) }
    func cancelVisitUseCase() -> CancelVisitUseCase { CancelVisitUseCase(visitRepository: visitRepository) }
    func getVisitHistoryUseCase() -> GetVisitHistoryUseCase { GetVisitHistoryUseCase(visitRepository: visitRepository) }
    func subscribeToPlanUseCase() -> SubscribeToPlanUseCase {
        SubscribeToPlanUseCase(subscriptionRepository: subscriptionRepository, paymentRepository: paymentRepository)
    }
    func sendChatMessageUseCase() -> SendChatMessageUseCase { SendChatMessageUseCase(chatRepository: chatRepository) }
    func submitReviewUseCase() -> SubmitReviewUseCase { SubmitReviewUseCase(reviewRepository: reviewRepository) }
    func managePetsUseCase() -> ManagePetsUseCase { ManagePetsUseCase(petRepository: petRepository) }
    func startCheckoutUseCase() -> StartCheckoutUseCase { StartCheckoutUseCase(paymentRepository: paymentRepository) }
}
