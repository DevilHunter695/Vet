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
    let cartRepository: CartRepository
    let quoteRepository: QuoteRepository
    let refundRepository: RefundRepository
    let invoiceRepository: InvoiceRepository
    let visitOTPRepository: VisitOTPRepository
    let consentRepository: ConsentRepository
    let accountRepository: AccountRepository
    let notificationPreferencesRepository: NotificationPreferencesRepository
    let appConfigRepository: AppConfigRepository

    private init() {
        // TODO: once Supabase package + Config.plist are added, branch here:
        // if RemoteAppConfig.isBackendConfigured { use Supabase*Repository } else { use Mock*Repository }
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
        self.cartRepository = MockCartRepository()
        self.quoteRepository = MockQuoteRepository()
        self.refundRepository = MockRefundRepository()
        self.invoiceRepository = MockInvoiceRepository()
        self.visitOTPRepository = MockVisitOTPRepository()
        self.consentRepository = MockConsentRepository()
        self.accountRepository = MockAccountRepository()
        self.notificationPreferencesRepository = MockNotificationPreferencesRepository()
        self.appConfigRepository = MockAppConfigRepository()
    }

    // MARK: Use case factories

    func getCircuitsUseCase() -> GetCircuitsUseCase { GetCircuitsUseCase(repository: circuitRepository) }
    func bookVisitUseCase() -> BookVisitUseCase { BookVisitUseCase(visitRepository: visitRepository) }
    func cancelVisitUseCase() -> CancelVisitUseCase { CancelVisitUseCase(visitRepository: visitRepository, refundRepository: refundRepository) }
    func rescheduleVisitUseCase() -> RescheduleVisitUseCase { RescheduleVisitUseCase(visitRepository: visitRepository) }
    func startVisitUseCase() -> StartVisitUseCase { StartVisitUseCase(visitOTPRepository: visitOTPRepository, visitRepository: visitRepository) }
    func manageConsentUseCase() -> ManageConsentUseCase { ManageConsentUseCase(consentRepository: consentRepository) }
    func manageAccountDeletionUseCase() -> ManageAccountDeletionUseCase {
        ManageAccountDeletionUseCase(accountRepository: accountRepository, authRepository: authRepository)
    }
    func exportDataUseCase() -> ExportDataUseCase { ExportDataUseCase(accountRepository: accountRepository) }
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
    func manageCartUseCase() -> ManageCartUseCase { ManageCartUseCase(cartRepository: cartRepository) }
    func getQuoteUseCase() -> GetQuoteUseCase { GetQuoteUseCase(quoteRepository: quoteRepository, catalogRepository: catalogRepository) }
    func manageNotificationPreferencesUseCase() -> ManageNotificationPreferencesUseCase {
        ManageNotificationPreferencesUseCase(repository: notificationPreferencesRepository)
    }
    func checkAppConfigUseCase() -> CheckAppConfigUseCase { CheckAppConfigUseCase(repository: appConfigRepository) }
}
