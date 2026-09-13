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
    let walletRepository: WalletRepository
    let couponRepository: CouponRepository
    let refundRepository: RefundRepository
    let invoiceRepository: InvoiceRepository
    let visitOTPRepository: VisitOTPRepository
    let consentRepository: ConsentRepository
    let accountRepository: AccountRepository
    let packageRepository: PackageRepository
    let notificationPreferencesRepository: NotificationPreferencesRepository
    let appConfigRepository: AppConfigRepository
    let helpRepository: HelpRepository
    let supportRepository: SupportRepository
    let appNotificationRepository: AppNotificationRepository
    let petWeightRepository: PetWeightRepository
    let vaccinationRepository: VaccinationRepository
    let prescriptionRepository: PrescriptionRepository
    /// C11: 24x7 emergency clinic directory.
    let emergencyClinicRepository: EmergencyClinicRepository
    let householdRepository: HouseholdRepository
    let waitlistRepository: WaitlistRepository
    let incidentReportRepository: IncidentReportRepository
    let subscriptionEntitlementRepository: SubscriptionEntitlementRepository
    /// D5: per-vet service availability/pricing overrides.
    let vetServiceOverrideRepository: VetServiceOverrideRepository
    /// F5: recurring booking rules.
    let recurringBookingRuleRepository: RecurringBookingRuleRepository
    /// F6: vet-initiated reschedule proposals.
    let rescheduleProposalRepository: RescheduleProposalRepository

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
        self.walletRepository = MockWalletRepository()
        self.couponRepository = MockCouponRepository()
        self.quoteRepository = MockQuoteRepository(couponRepository: couponRepository, walletRepository: walletRepository)
        self.refundRepository = MockRefundRepository()
        self.invoiceRepository = MockInvoiceRepository()
        self.visitOTPRepository = MockVisitOTPRepository()
        self.consentRepository = MockConsentRepository()
        self.accountRepository = MockAccountRepository()
        self.packageRepository = MockPackageRepository()
        self.notificationPreferencesRepository = MockNotificationPreferencesRepository()
        self.appConfigRepository = MockAppConfigRepository()
        self.helpRepository = MockHelpRepository()
        self.supportRepository = MockSupportRepository()
        self.appNotificationRepository = MockAppNotificationRepository()
        self.petWeightRepository = MockPetWeightRepository()
        self.vaccinationRepository = MockVaccinationRepository()
        self.prescriptionRepository = MockPrescriptionRepository()
        self.emergencyClinicRepository = MockEmergencyClinicRepository()
        self.householdRepository = MockHouseholdRepository()
        self.waitlistRepository = MockWaitlistRepository()
        self.incidentReportRepository = MockIncidentReportRepository()
        self.subscriptionEntitlementRepository = MockSubscriptionEntitlementRepository()
        self.vetServiceOverrideRepository = MockVetServiceOverrideRepository()
        self.recurringBookingRuleRepository = MockRecurringBookingRuleRepository()
        self.rescheduleProposalRepository = MockRescheduleProposalRepository()
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
    func manageSubscriptionUseCase() -> ManageSubscriptionUseCase {
        ManageSubscriptionUseCase(subscriptionRepository: subscriptionRepository)
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
    func getQuoteUseCase() -> GetQuoteUseCase {
        GetQuoteUseCase(quoteRepository: quoteRepository, catalogRepository: catalogRepository,
                         circuitRepository: circuitRepository, vetServiceOverrideRepository: vetServiceOverrideRepository,
                         subscriptionRepository: subscriptionRepository, entitlementRepository: subscriptionEntitlementRepository)
    }
    func getWalletBalanceUseCase() -> GetWalletBalanceUseCase { GetWalletBalanceUseCase(walletRepository: walletRepository) }
    func applyCouponUseCase() -> ApplyCouponUseCase { ApplyCouponUseCase(couponRepository: couponRepository) }
    func tipUseCase() -> TipUseCase { TipUseCase(paymentRepository: paymentRepository) }
    func manageRecurringBookingUseCase() -> ManageRecurringBookingUseCase {
        ManageRecurringBookingUseCase(recurringBookingRuleRepository: recurringBookingRuleRepository)
    }
    func respondToRescheduleProposalUseCase() -> RespondToRescheduleProposalUseCase {
        RespondToRescheduleProposalUseCase(proposalRepository: rescheduleProposalRepository, visitRepository: visitRepository,
                                            circuitRepository: circuitRepository, loyaltyRepository: loyaltyRepository)
    }
    func reportVetNoShowUseCase() -> ReportVetNoShowUseCase {
        ReportVetNoShowUseCase(visitRepository: visitRepository, refundRepository: refundRepository, loyaltyRepository: loyaltyRepository)
    }
    func browsePackagesUseCase() -> BrowsePackagesUseCase { BrowsePackagesUseCase(packageRepository: packageRepository) }
    func buyPackageUseCase() -> BuyPackageUseCase {
        BuyPackageUseCase(packageRepository: packageRepository, catalogRepository: catalogRepository, cartRepository: cartRepository)
    }
    func manageNotificationPreferencesUseCase() -> ManageNotificationPreferencesUseCase {
        ManageNotificationPreferencesUseCase(repository: notificationPreferencesRepository)
    }
    func checkAppConfigUseCase() -> CheckAppConfigUseCase { CheckAppConfigUseCase(repository: appConfigRepository) }
    func getHelpArticlesUseCase() -> GetHelpArticlesUseCase { GetHelpArticlesUseCase(repository: helpRepository) }
    func contactSupportUseCase() -> ContactSupportUseCase { ContactSupportUseCase(repository: supportRepository) }
    func getNotificationCenterUseCase() -> GetNotificationCenterUseCase { GetNotificationCenterUseCase(repository: appNotificationRepository) }
    func managePetWeightsUseCase() -> ManagePetWeightsUseCase { ManagePetWeightsUseCase(repository: petWeightRepository) }
    func manageVaccinationsUseCase() -> ManageVaccinationsUseCase { ManageVaccinationsUseCase(repository: vaccinationRepository) }
    func managePrescriptionsUseCase() -> ManagePrescriptionsUseCase { ManagePrescriptionsUseCase(repository: prescriptionRepository) }
    func listEmergencyClinicsUseCase() -> ListEmergencyClinicsUseCase { ListEmergencyClinicsUseCase(repository: emergencyClinicRepository) }
    func getVetProfileUseCase() -> GetVetProfileUseCase { GetVetProfileUseCase(reviewRepository: reviewRepository) }
    func manageHouseholdUseCase() -> ManageHouseholdUseCase { ManageHouseholdUseCase(householdRepository: householdRepository) }
    func searchUseCase() -> SearchUseCase { SearchUseCase(circuitRepository: circuitRepository, catalogRepository: catalogRepository) }
    func rebookLastVisitUseCase() -> RebookLastVisitUseCase { RebookLastVisitUseCase(visitRepository: visitRepository, circuitRepository: circuitRepository) }
    func joinWaitlistUseCase() -> JoinWaitlistUseCase { JoinWaitlistUseCase(waitlistRepository: waitlistRepository) }
    func fileIncidentReportUseCase() -> FileIncidentReportUseCase { FileIncidentReportUseCase(repository: incidentReportRepository) }
    func sosUseCase() -> SOSUseCase { SOSUseCase(incidentReportRepository: incidentReportRepository) }
}
