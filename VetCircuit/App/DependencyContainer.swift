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
    let liveTrackingRepository: LiveTrackingRepository
    let callRepository: CallRepository
    let referralRepository: ReferralRepository
    let triageRepository: TriageRepository
    let loyaltyRepository: LoyaltyRepository
    let catalogRepository: CatalogRepository
    let addressRepository: AddressRepository
    let slotHoldRepository: SlotHoldRepository

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
        self.liveTrackingRepository = MockLiveTrackingRepository()
        self.callRepository = MockCallRepository()
        self.referralRepository = MockReferralRepository()
        self.triageRepository = MockTriageRepository()
        self.loyaltyRepository = MockLoyaltyRepository()
        self.catalogRepository = MockCatalogRepository()
        self.addressRepository = MockAddressRepository()
        self.slotHoldRepository = MockSlotHoldRepository()
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
    func trackVetUseCase() -> TrackVetUseCase { TrackVetUseCase(liveTrackingRepository: liveTrackingRepository) }
    func startCallUseCase() -> StartCallUseCase { StartCallUseCase(callRepository: callRepository) }
    func sendReferralUseCase() -> SendReferralUseCase { SendReferralUseCase(referralRepository: referralRepository) }
    func runTriageUseCase() -> RunTriageUseCase { RunTriageUseCase(triageRepository: triageRepository) }
    func getLoyaltyAccountUseCase() -> GetLoyaltyAccountUseCase { GetLoyaltyAccountUseCase(loyaltyRepository: loyaltyRepository) }
    func getCatalogUseCase() -> GetCatalogUseCase { GetCatalogUseCase(catalogRepository: catalogRepository) }
    func manageAddressesUseCase() -> ManageAddressesUseCase { ManageAddressesUseCase(addressRepository: addressRepository) }
    func holdSlotUseCase() -> HoldSlotUseCase { HoldSlotUseCase(circuitRepository: circuitRepository, slotHoldRepository: slotHoldRepository) }
}
