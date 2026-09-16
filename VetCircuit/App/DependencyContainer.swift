import Foundation
import Supabase

/// Central composition root.
///
/// This used to be mock-only with a `TODO` describing the branch that was
/// supposed to exist, which made "swap in the real backend" a code change
/// nobody could stage or review — the single largest thing standing between
/// this app and a deployment. The branch is now real: supply `SUPABASE_URL`
/// and `SUPABASE_ANON_KEY` in the app's Info.plist and every repository that
/// has a Supabase conformer switches to it. Supply neither and the app runs
/// exactly as it does today, on mocks, with the demo data.
///
/// It has never run against a live database. What this buys is that the
/// remaining distance is now *configuration plus debugging*, not authorship,
/// and `backendMode` says out loud which of the two an installed build is in
/// instead of leaving it to be inferred.
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
    /// B6: document vault.
    let petDocumentRepository: PetDocumentRepository
    /// E9: saved payment methods (gateway token reference only).
    let savedPaymentMethodRepository: SavedPaymentMethodRepository
    /// M4: support-issued refunds/credits, with audit trail.
    let supportRefundAuditRepository: SupportRefundAuditRepository
    /// F9: vet leave/holiday blackout windows.
    let vetBlackoutRepository: VetBlackoutRepository
    /// K3: medication reminders.
    let medicationReminderRepository: MedicationReminderRepository
    /// G9: gateway chargebacks/disputes, read-only on the customer side.
    let paymentDisputeRepository: PaymentDisputeRepository
    /// J8: SMS/WhatsApp fallback intent when push fails (no real gateway wired).
    let smsFallbackRepository: SMSFallbackRepository
    /// K6: lab test reports (read-only; uploaded ops-side).
    let labTestReportRepository: LabTestReportRepository
    /// L2: document-backed vet onboarding applications (domain/data layer
    /// only — this app has no vet-facing UI to submit one from).
    let vetOnboardingRepository: VetOnboardingRepository
    /// I7: the vet's in-visit checklist, read-only from the customer side.
    let visitChecklistRepository: VisitChecklistRepository
    /// I8: device-local dedupe for the post-visit summary push.
    let postVisitSummaryRepository: PostVisitSummaryRepository
    /// F4: device-local dedupe for client-detected no-show flagging.
    let noShowDetectionRepository: NoShowDetectionRepository
    /// H4: device-local dedupe for the client-detected renewal reminder push.
    let renewalReminderDedupeRepository: RenewalReminderDedupeRepository
    /// H7: corporate/RWA seat assignment roster.
    let corporateSeatAssignmentRepository: CorporateSeatAssignmentRepository

    /// Which set of repositories this build actually resolved. Surfaced so a
    /// build can say what it is connected to rather than looking identical
    /// either way — the failure mode where a "staging" build is quietly
    /// serving mock data is worth making impossible to miss.
    enum BackendMode: String {
        /// No credentials configured. Every repository is a mock and all data
        /// is the seeded demo set.
        case mock
        /// Credentials present. The 48 repositories with a Supabase conformer
        /// talk to Postgres; the nine listed in `mockOnlyRepositories` below
        /// stay on mocks because no Supabase implementation exists for them
        /// yet, and they are the remaining work before a real deployment.
        case supabase
    }

    let backendMode: BackendMode

    /// Named, not counted. In a credentialed build these still serve mock
    /// data, and anyone deploying needs to know exactly which surfaces are
    /// affected rather than reading "48 of 57" and assuming the rest are
    /// unimportant. Chat and live tracking are the two that would be noticed
    /// first by a customer.
    static let mockOnlyRepositories = [
        "ChatRepository", "LiveTrackingRepository", "NoShowDetectionRepository",
        "PaymentRepository", "PostVisitSummaryRepository", "PushTokenRepository",
        "ReferralRepository", "RenewalReminderDedupeRepository", "TriageRepository",
    ]

    private init() {
        // One client, shared by every Supabase repository. Nil whenever the
        // credentials are absent, which is what drives the whole branch below.
        let client: SupabaseClient? = {
            guard let url = AppConfig.supabaseURL, let key = AppConfig.supabaseAnonKey else { return nil }
            return SupabaseClient(supabaseURL: url, supabaseKey: key)
        }()
        self.backendMode = client == nil ? .mock : .supabase

        self.authRepository = client.map(SupabaseAuthRepository.init) ?? MockAuthRepository()
        self.circuitRepository = client.map(SupabaseCircuitRepository.init) ?? MockCircuitRepository()
        // D4: created before visitRepository and threaded into it so a
        // package-redeeming booking can atomically bump the matching
        // `PackageRedemption.usedCount` — same "concrete mock reference"
        // pattern `mockWalletRepository`/`loyaltyRepository` use below.
        let mockPackageRepository = MockPackageRepository()
        self.packageRepository = client.map(SupabasePackageRepository.init) ?? mockPackageRepository
        // The mock pair is threaded so a package-redeeming booking bumps the
        // matching redemption in the same actor; against Postgres that
        // atomicity is the database's job, so the Supabase pair needs no
        // equivalent wiring.
        self.visitRepository = client.map(SupabaseVisitRepository.init)
            ?? MockVisitRepository(packageRepository: mockPackageRepository, seed: MockData.visits)
        self.subscriptionRepository = client.map(SupabaseSubscriptionRepository.init) ?? MockSubscriptionRepository()
        self.paymentRepository = MockPaymentRepository()
        self.chatRepository = MockChatRepository()
        self.reviewRepository = client.map(SupabaseReviewRepository.init) ?? MockReviewRepository()
        self.petRepository = client.map(SupabasePetRepository.init) ?? MockPetRepository()
        self.pushTokenRepository = MockPushTokenRepository()
        self.liveTrackingRepository = MockLiveTrackingRepository()
        self.callRepository = client.map(SupabaseCallRepository.init) ?? MockCallRepository()
        self.referralRepository = MockReferralRepository()
        self.triageRepository = MockTriageRepository()
        self.catalogRepository = client.map(SupabaseCatalogRepository.init) ?? MockCatalogRepository()
        self.addressRepository = client.map(SupabaseAddressRepository.init) ?? MockAddressRepository()
        self.slotHoldRepository = client.map(SupabaseSlotHoldRepository.init) ?? MockSlotHoldRepository()
        self.cartRepository = client.map(SupabaseCartRepository.init) ?? MockCartRepository()
        // The running app opts into the demo ledger and a lived-in loyalty
        // balance; tests construct these repositories bare (see their inits).
        let mockWalletRepository = MockWalletRepository(includesDemoHistory: true)
        self.walletRepository = client.map(SupabaseWalletRepository.init) ?? mockWalletRepository
        // E5: concrete `MockWalletRepository` reference so a mock point
        // redemption can actually credit the mock wallet too — see
        // `MockWalletRepository.creditFromLoyaltyRedemption`'s doc comment.
        // Against Postgres, redeeming points moves the wallet in one RPC
        // (0050_redeem_loyalty_points.sql), so the concrete wallet reference
        // the mock needs has no Supabase counterpart.
        self.loyaltyRepository = client.map(SupabaseLoyaltyRepository.init)
            ?? MockLoyaltyRepository(
                walletRepository: mockWalletRepository,
                demoStartingAccount: LoyaltyAccount(userId: MockData.userId, points: 1_240, tier: .silver)
            )
        self.couponRepository = client.map(SupabaseCouponRepository.init) ?? MockCouponRepository()
        // The mock composes coupon + wallet locally to imitate what the
        // server-signed quote does; the real one is a single RPC.
        self.quoteRepository = client.map(SupabaseQuoteRepository.init)
            ?? MockQuoteRepository(couponRepository: couponRepository, walletRepository: walletRepository)
        self.refundRepository = client.map(SupabaseRefundRepository.init) ?? MockRefundRepository()
        self.invoiceRepository = client.map(SupabaseInvoiceRepository.init) ?? MockInvoiceRepository()
        self.visitOTPRepository = client.map(SupabaseVisitOTPRepository.init) ?? MockVisitOTPRepository()
        self.consentRepository = client.map(SupabaseConsentRepository.init) ?? MockConsentRepository()
        self.accountRepository = client.map(SupabaseAccountRepository.init) ?? MockAccountRepository()
        self.notificationPreferencesRepository = client.map(SupabaseNotificationPreferencesRepository.init) ?? MockNotificationPreferencesRepository()
        self.appConfigRepository = client.map(SupabaseAppConfigRepository.init) ?? MockAppConfigRepository()
        self.helpRepository = client.map(SupabaseHelpRepository.init) ?? MockHelpRepository()
        self.supportRepository = client.map(SupabaseSupportRepository.init) ?? MockSupportRepository()
        self.appNotificationRepository = client.map(SupabaseAppNotificationRepository.init) ?? MockAppNotificationRepository()
        self.petWeightRepository = client.map(SupabasePetWeightRepository.init) ?? MockPetWeightRepository()
        self.vaccinationRepository = client.map(SupabaseVaccinationRepository.init) ?? MockVaccinationRepository()
        self.prescriptionRepository = client.map(SupabasePrescriptionRepository.init) ?? MockPrescriptionRepository()
        self.emergencyClinicRepository = client.map(SupabaseEmergencyClinicRepository.init) ?? MockEmergencyClinicRepository()
        self.householdRepository = client.map(SupabaseHouseholdRepository.init) ?? MockHouseholdRepository()
        self.waitlistRepository = client.map(SupabaseWaitlistRepository.init) ?? MockWaitlistRepository()
        self.incidentReportRepository = client.map(SupabaseIncidentReportRepository.init) ?? MockIncidentReportRepository()
        self.subscriptionEntitlementRepository = client.map(SupabaseSubscriptionEntitlementRepository.init) ?? MockSubscriptionEntitlementRepository()
        self.vetServiceOverrideRepository = client.map(SupabaseVetServiceOverrideRepository.init) ?? MockVetServiceOverrideRepository()
        self.recurringBookingRuleRepository = client.map(SupabaseRecurringBookingRuleRepository.init) ?? MockRecurringBookingRuleRepository()
        self.rescheduleProposalRepository = client.map(SupabaseRescheduleProposalRepository.init) ?? MockRescheduleProposalRepository()
        self.petDocumentRepository = client.map(SupabasePetDocumentRepository.init) ?? MockPetDocumentRepository()
        self.savedPaymentMethodRepository = client.map(SupabaseSavedPaymentMethodRepository.init) ?? MockSavedPaymentMethodRepository()
        self.supportRefundAuditRepository = client.map(SupabaseSupportRefundAuditRepository.init)
            ?? MockSupportRefundAuditRepository(refundRepository: refundRepository)
        self.vetBlackoutRepository = client.map(SupabaseVetBlackoutRepository.init) ?? MockVetBlackoutRepository()
        self.medicationReminderRepository = client.map(SupabaseMedicationReminderRepository.init) ?? MockMedicationReminderRepository()
        self.paymentDisputeRepository = client.map(SupabasePaymentDisputeRepository.init) ?? MockPaymentDisputeRepository()
        self.smsFallbackRepository = client.map(SupabaseSMSFallbackRepository.init) ?? MockSMSFallbackRepository()
        self.labTestReportRepository = client.map(SupabaseLabTestReportRepository.init) ?? MockLabTestReportRepository()
        self.vetOnboardingRepository = client.map(SupabaseVetOnboardingRepository.init) ?? MockVetOnboardingRepository()
        self.visitChecklistRepository = client.map(SupabaseVisitChecklistRepository.init) ?? MockVisitChecklistRepository()
        self.postVisitSummaryRepository = LocalPostVisitSummaryRepository()
        self.noShowDetectionRepository = LocalNoShowDetectionRepository()
        self.renewalReminderDedupeRepository = LocalRenewalReminderDedupeRepository()
        self.corporateSeatAssignmentRepository = client.map(SupabaseCorporateSeatAssignmentRepository.init) ?? MockCorporateSeatAssignmentRepository()
    }

    // MARK: Use case factories

    func getCircuitsUseCase() -> GetCircuitsUseCase { GetCircuitsUseCase(repository: circuitRepository, vetBlackoutRepository: vetBlackoutRepository) }
    func manageVetBlackoutsUseCase() -> ManageVetBlackoutsUseCase { ManageVetBlackoutsUseCase(repository: vetBlackoutRepository) }
    func manageMedicationRemindersUseCase() -> ManageMedicationRemindersUseCase { ManageMedicationRemindersUseCase(repository: medicationReminderRepository) }
    func bookVisitUseCase() -> BookVisitUseCase { BookVisitUseCase(visitRepository: visitRepository) }
    func cancelVisitUseCase() -> CancelVisitUseCase { CancelVisitUseCase(visitRepository: visitRepository, refundRepository: refundRepository) }
    /// F4: client-detected no-show flagging, called from `VisitHistoryView`'s
    /// load — see `FlagVisitNoShowUseCase`'s doc comment.
    func flagVisitNoShowUseCase() -> FlagVisitNoShowUseCase {
        FlagVisitNoShowUseCase(cancelVisitUseCase: cancelVisitUseCase(), noShowDetectionRepository: noShowDetectionRepository)
    }
    func rescheduleVisitUseCase() -> RescheduleVisitUseCase { RescheduleVisitUseCase(visitRepository: visitRepository) }
    func startVisitUseCase() -> StartVisitUseCase { StartVisitUseCase(visitOTPRepository: visitOTPRepository, visitRepository: visitRepository) }
    func manageConsentUseCase() -> ManageConsentUseCase { ManageConsentUseCase(consentRepository: consentRepository) }
    func manageAccountDeletionUseCase() -> ManageAccountDeletionUseCase {
        ManageAccountDeletionUseCase(accountRepository: accountRepository, authRepository: authRepository)
    }
    func exportDataUseCase() -> ExportDataUseCase { ExportDataUseCase(accountRepository: accountRepository) }
    func editProfileUseCase() -> EditProfileUseCase { EditProfileUseCase(accountRepository: accountRepository) }
    func getVisitHistoryUseCase() -> GetVisitHistoryUseCase { GetVisitHistoryUseCase(visitRepository: visitRepository) }
    func subscribeToPlanUseCase() -> SubscribeToPlanUseCase {
        SubscribeToPlanUseCase(subscriptionRepository: subscriptionRepository, paymentRepository: paymentRepository)
    }
    func manageSubscriptionUseCase() -> ManageSubscriptionUseCase {
        ManageSubscriptionUseCase(subscriptionRepository: subscriptionRepository)
    }
    /// H5: dunning — read-only retry/grace status, and grace-expiry resolution.
    func dunningStatusUseCase() -> DunningStatusUseCase { DunningStatusUseCase(subscriptionRepository: subscriptionRepository) }
    func sendChatMessageUseCase() -> SendChatMessageUseCase { SendChatMessageUseCase(chatRepository: chatRepository) }
    func submitReviewUseCase() -> SubmitReviewUseCase { SubmitReviewUseCase(reviewRepository: reviewRepository) }
    func managePetsUseCase() -> ManagePetsUseCase { ManagePetsUseCase(petRepository: petRepository) }
    func startCheckoutUseCase() -> StartCheckoutUseCase { StartCheckoutUseCase(paymentRepository: paymentRepository) }

    /// E6+E8+E10+G6: the coordinating quote -> checkout -> confirmed-visit pipeline.
    func bookingCheckoutUseCase() -> BookingCheckoutUseCase {
        BookingCheckoutUseCase(
            bookVisitUseCase: bookVisitUseCase(), startCheckoutUseCase: startCheckoutUseCase(),
            visitRepository: visitRepository, paymentRepository: paymentRepository
        )
    }
    /// G3: payment retry on failure.
    func retryPaymentUseCase() -> RetryPaymentUseCase { RetryPaymentUseCase(paymentRepository: paymentRepository) }
    /// E8: marks a pay-after-visit payment collected once the visit is completed.
    func markPayAfterVisitCollectedUseCase() -> MarkPayAfterVisitCollectedUseCase {
        MarkPayAfterVisitCollectedUseCase(visitRepository: visitRepository, paymentRepository: paymentRepository)
    }
    func trackVetUseCase() -> TrackVetUseCase { TrackVetUseCase(liveTrackingRepository: liveTrackingRepository) }
    func startCallUseCase() -> StartCallUseCase { StartCallUseCase(callRepository: callRepository) }
    func sendReferralUseCase() -> SendReferralUseCase { SendReferralUseCase(referralRepository: referralRepository) }
    func runTriageUseCase() -> RunTriageUseCase { RunTriageUseCase(triageRepository: triageRepository) }
    func getLoyaltyAccountUseCase() -> GetLoyaltyAccountUseCase { GetLoyaltyAccountUseCase(loyaltyRepository: loyaltyRepository) }
    /// E5: loyalty point redemption at checkout.
    func redeemLoyaltyPointsUseCase() -> RedeemLoyaltyPointsUseCase { RedeemLoyaltyPointsUseCase(loyaltyRepository: loyaltyRepository) }
    func getCatalogUseCase() -> GetCatalogUseCase { GetCatalogUseCase(catalogRepository: catalogRepository) }
    func manageAddressesUseCase() -> ManageAddressesUseCase { ManageAddressesUseCase(addressRepository: addressRepository) }
    /// C7: served-cluster coverage for the map view.
    func getServedClustersUseCase() -> GetServedClustersUseCase { GetServedClustersUseCase(addressRepository: addressRepository) }
    func holdSlotUseCase() -> HoldSlotUseCase { HoldSlotUseCase(circuitRepository: circuitRepository, slotHoldRepository: slotHoldRepository) }
    // D3: the catalog and pet repositories are what make the add-on
    // eligibility gate actually run. Leaving them off (they default to nil)
    // compiles perfectly and silently disables the check — the same failure
    // mode as the species gate that shadowed its own parameter and always
    // returned true. Wiring is part of the fix, not an optional extra.
    func manageCartUseCase() -> ManageCartUseCase {
        ManageCartUseCase(cartRepository: cartRepository, catalogRepository: catalogRepository,
                          petRepository: petRepository)
    }
    func getQuoteUseCase() -> GetQuoteUseCase {
        GetQuoteUseCase(quoteRepository: quoteRepository, catalogRepository: catalogRepository,
                         circuitRepository: circuitRepository, vetServiceOverrideRepository: vetServiceOverrideRepository,
                         subscriptionRepository: subscriptionRepository, entitlementRepository: subscriptionEntitlementRepository,
                         petRepository: petRepository)
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
    func getMyPackageRedemptionsUseCase() -> GetMyPackageRedemptionsUseCase {
        GetMyPackageRedemptionsUseCase(packageRepository: packageRepository, catalogRepository: catalogRepository)
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
    func manageHouseholdUseCase() -> ManageHouseholdUseCase {
        ManageHouseholdUseCase(householdRepository: householdRepository, petRepository: petRepository, visitRepository: visitRepository)
    }
    func searchUseCase() -> SearchUseCase { SearchUseCase(circuitRepository: circuitRepository, catalogRepository: catalogRepository) }
    func rebookLastVisitUseCase() -> RebookLastVisitUseCase { RebookLastVisitUseCase(visitRepository: visitRepository, circuitRepository: circuitRepository) }
    func joinWaitlistUseCase() -> JoinWaitlistUseCase { JoinWaitlistUseCase(waitlistRepository: waitlistRepository) }
    func fileIncidentReportUseCase() -> FileIncidentReportUseCase { FileIncidentReportUseCase(repository: incidentReportRepository) }
    func sosUseCase() -> SOSUseCase { SOSUseCase(incidentReportRepository: incidentReportRepository) }
    func managePetDocumentsUseCase() -> ManagePetDocumentsUseCase { ManagePetDocumentsUseCase(repository: petDocumentRepository) }
    func generatePetHealthSummaryUseCase() -> GeneratePetHealthSummaryUseCase { GeneratePetHealthSummaryUseCase() }
    func manageSavedPaymentMethodsUseCase() -> ManageSavedPaymentMethodsUseCase {
        ManageSavedPaymentMethodsUseCase(repository: savedPaymentMethodRepository)
    }
    func issueSupportRefundUseCase() -> IssueSupportRefundUseCase {
        IssueSupportRefundUseCase(repository: supportRefundAuditRepository)
    }
    /// M5: business-hours-gated support number, checked via `tel:`.
    func contactSupportByCallUseCase() -> ContactSupportByCallUseCase {
        ContactSupportByCallUseCase(supportPhoneNumber: "+911800123456")
    }
    /// J8: decides push vs SMS-fallback vs suppressed for a transactional
    /// notification, and records the fallback intent when one is sent.
    func sendTransactionalNotificationUseCase() -> SendTransactionalNotificationUseCase {
        SendTransactionalNotificationUseCase(
            pushTokenRepository: pushTokenRepository,
            notificationPreferencesRepository: notificationPreferencesRepository,
            smsFallbackRepository: smsFallbackRepository
        )
    }
    /// H4: T-7/T-1 subscription renewal reminders, deduped per subscription
    /// + stage + day — see `RenewalReminderUseCase`'s doc comment for where
    /// this is actually invoked from.
    func renewalReminderUseCase() -> RenewalReminderUseCase {
        RenewalReminderUseCase(
            sendTransactionalNotificationUseCase: sendTransactionalNotificationUseCase(),
            dedupeRepository: renewalReminderDedupeRepository
        )
    }
    /// K6: lab test reports attached to a visit/pet.
    func getLabTestReportsUseCase() -> GetLabTestReportsUseCase {
        GetLabTestReportsUseCase(repository: labTestReportRepository)
    }
    /// L2: document-backed vet onboarding (domain/data layer only).
    func submitVetOnboardingApplicationUseCase() -> SubmitVetOnboardingApplicationUseCase {
        SubmitVetOnboardingApplicationUseCase(repository: vetOnboardingRepository)
    }
    /// I7: the vet's in-visit checklist, once it becomes the customer's record.
    func getVisitChecklistUseCase() -> GetVisitChecklistUseCase {
        GetVisitChecklistUseCase(repository: visitChecklistRepository)
    }
    /// I8: post-visit summary push, de-duplicated on-device.
    func sendPostVisitSummaryUseCase() -> SendPostVisitSummaryUseCase {
        SendPostVisitSummaryUseCase(sendTransactionalNotificationUseCase: sendTransactionalNotificationUseCase(), postVisitSummaryRepository: postVisitSummaryRepository)
    }
    /// H7: corporate/RWA seat assignment.
    func manageCorporateSeatsUseCase() -> ManageCorporateSeatsUseCase {
        ManageCorporateSeatsUseCase(repository: corporateSeatAssignmentRepository)
    }
    /// N3: drains the server-queued lifecycle notification queue (see
    /// `DrainLifecycleNotificationQueueUseCase`'s doc comment for where
    /// this is actually invoked from).
    func drainLifecycleNotificationQueueUseCase() -> DrainLifecycleNotificationQueueUseCase {
        DrainLifecycleNotificationQueueUseCase(
            repository: appNotificationRepository,
            sendTransactionalNotificationUseCase: sendTransactionalNotificationUseCase()
        )
    }
}
