import Testing
import Foundation
@testable import VetCircuit

// J8/K6: SMS/WhatsApp fallback delivery policy + lab test report delivery.

@Suite("NotificationDeliveryPolicy")
struct NotificationDeliveryPolicyTests {
    @Test("uses push when a token exists and delivery hasn't failed")
    func usesPush() {
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: true, pushDeliveryFailed: false,
            preferences: NotificationPreferences(userId: UUID()),
            category: .visitConfirmed, hasPhoneNumber: true
        )
        #expect(decision == .push)
    }

    @Test("falls back to SMS when there's no push token at all")
    func fallsBackWhenNoToken() {
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: false, pushDeliveryFailed: false,
            preferences: NotificationPreferences(userId: UUID()),
            category: .vetEnRoute, hasPhoneNumber: true
        )
        #expect(decision == .smsFallback(reason: .noPushToken))
    }

    @Test("falls back to SMS when a push send just failed")
    func fallsBackOnDeliveryFailure() {
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: true, pushDeliveryFailed: true,
            preferences: NotificationPreferences(userId: UUID()),
            category: .visitCompleted, hasPhoneNumber: true
        )
        #expect(decision == .smsFallback(reason: .pushDeliveryFailed))
    }

    @Test("falls back to SMS when the user has booking-update push disabled")
    func fallsBackWhenDisabledByUser() {
        var prefs = NotificationPreferences(userId: UUID())
        prefs.bookingUpdates = false
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: true, pushDeliveryFailed: false,
            preferences: prefs, category: .rescheduleProposed, hasPhoneNumber: true
        )
        #expect(decision == .smsFallback(reason: .pushDisabledByUser))
    }

    @Test("an OTP always tries to reach the user even if booking updates are off")
    func otpIgnoresBookingUpdatesToggle() {
        var prefs = NotificationPreferences(userId: UUID())
        prefs.bookingUpdates = false
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: true, pushDeliveryFailed: false,
            preferences: prefs, category: .otp, hasPhoneNumber: true
        )
        #expect(decision == .push)
    }

    @Test("suppressed when no channel is viable at all")
    func suppressedWithNoChannel() {
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: false, pushDeliveryFailed: false,
            preferences: NotificationPreferences(userId: UUID()),
            category: .visitConfirmed, hasPhoneNumber: false
        )
        if case .suppressed = decision {
            // expected
        } else {
            Issue.record("expected suppressed, got \(decision)")
        }
    }

    @Test("no preferences on file still falls back when there's no token (defaults on)")
    func fallsBackWithNilPreferences() {
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: false, pushDeliveryFailed: false,
            preferences: nil, category: .visitConfirmed, hasPhoneNumber: true
        )
        #expect(decision == .smsFallback(reason: .noPushToken))
    }
}

@Suite("SendTransactionalNotificationUseCase")
struct SendTransactionalNotificationUseCaseTests {
    @Test("records an SMS fallback when the user has no push token")
    func recordsFallbackWhenNoToken() async throws {
        let pushRepo = MockPushTokenRepository()
        let prefsRepo = MockNotificationPreferencesRepository()
        let smsRepo = MockSMSFallbackRepository()
        let useCase = SendTransactionalNotificationUseCase(
            pushTokenRepository: pushRepo, notificationPreferencesRepository: prefsRepo, smsFallbackRepository: smsRepo
        )
        var user = MockData.user
        user.phone = "+919876543210"

        let decision = try await useCase.execute(user: user, category: .visitConfirmed, body: "Your visit is confirmed.")

        #expect(decision == .smsFallback(reason: .noPushToken))
        let records = await smsRepo.sentRecords
        #expect(records.count == 1)
        #expect(records.first?.phone == "+919876543210")
        #expect(records.first?.category == .visitConfirmed)
    }

    @Test("uses push, not SMS, once a device token is registered")
    func noFallbackOnceTokenRegistered() async throws {
        let pushRepo = MockPushTokenRepository()
        let prefsRepo = MockNotificationPreferencesRepository()
        let smsRepo = MockSMSFallbackRepository()
        let useCase = SendTransactionalNotificationUseCase(
            pushTokenRepository: pushRepo, notificationPreferencesRepository: prefsRepo, smsFallbackRepository: smsRepo
        )
        let user = MockData.user
        try await pushRepo.registerDeviceToken("device-token", userId: user.id)

        let decision = try await useCase.execute(user: user, category: .vetEnRoute, body: "Your vet is on the way.")

        #expect(decision == .push)
        let records = await smsRepo.sentRecords
        #expect(records.isEmpty)
    }

    @Test("falls back when told push delivery just failed, even with a token on file")
    func fallsBackOnExplicitDeliveryFailure() async throws {
        let pushRepo = MockPushTokenRepository()
        let prefsRepo = MockNotificationPreferencesRepository()
        let smsRepo = MockSMSFallbackRepository()
        let useCase = SendTransactionalNotificationUseCase(
            pushTokenRepository: pushRepo, notificationPreferencesRepository: prefsRepo, smsFallbackRepository: smsRepo
        )
        var user = MockData.user
        user.phone = "+919876543210"
        try await pushRepo.registerDeviceToken("device-token", userId: user.id)

        let decision = try await useCase.execute(user: user, category: .visitCompleted, body: "Your visit is complete.", pushDeliveryFailed: true)

        #expect(decision == .smsFallback(reason: .pushDeliveryFailed))
        let records = await smsRepo.sentRecords
        #expect(records.count == 1)
    }

    @Test("no phone on file suppresses rather than crashing")
    func suppressesWithoutPhone() async throws {
        let pushRepo = MockPushTokenRepository()
        let prefsRepo = MockNotificationPreferencesRepository()
        let smsRepo = MockSMSFallbackRepository()
        let useCase = SendTransactionalNotificationUseCase(
            pushTokenRepository: pushRepo, notificationPreferencesRepository: prefsRepo, smsFallbackRepository: smsRepo
        )
        var user = MockData.user
        user.phone = nil

        let decision = try await useCase.execute(user: user, category: .visitConfirmed, body: "Your visit is confirmed.")

        if case .suppressed = decision {
            // expected
        } else {
            Issue.record("expected suppressed, got \(decision)")
        }
        let records = await smsRepo.sentRecords
        #expect(records.isEmpty)
    }
}

@Suite("GetLabTestReportsUseCase")
struct GetLabTestReportsUseCaseTests {
    @Test("returns only the reports for the requested pet")
    func filtersByPet() async throws {
        let petId = UUID()
        let otherPetId = UUID()
        let visitId = UUID()
        let repo = MockLabTestReportRepository(seed: [
            LabTestReport(id: UUID(), visitId: visitId, petId: petId, testName: "Blood panel", status: .ready,
                          reportFileURL: URL(string: "mock-storage://x"), resultSummary: "Normal", availableAt: .now),
            LabTestReport(id: UUID(), visitId: visitId, petId: otherPetId, testName: "Urinalysis", status: .pending,
                          reportFileURL: nil, resultSummary: nil, availableAt: nil),
        ])
        let useCase = GetLabTestReportsUseCase(repository: repo)

        let reports = try await useCase.forPet(petId)

        #expect(reports.count == 1)
        #expect(reports.first?.testName == "Blood panel")
    }

    @Test("returns only the reports for the requested visit")
    func filtersByVisit() async throws {
        let petId = UUID()
        let visitId = UUID()
        let otherVisitId = UUID()
        let repo = MockLabTestReportRepository(seed: [
            LabTestReport(id: UUID(), visitId: visitId, petId: petId, testName: "Blood panel", status: .pending,
                          reportFileURL: nil, resultSummary: nil, availableAt: nil),
            LabTestReport(id: UUID(), visitId: otherVisitId, petId: petId, testName: "Urinalysis", status: .pending,
                          reportFileURL: nil, resultSummary: nil, availableAt: nil),
        ])
        let useCase = GetLabTestReportsUseCase(repository: repo)

        let reports = try await useCase.forVisit(visitId)

        #expect(reports.count == 1)
        #expect(reports.first?.testName == "Blood panel")
    }

    @Test("a pending report has no report file or summary yet")
    func pendingReportHasNoFileOrSummary() async throws {
        let petId = UUID()
        let repo = MockLabTestReportRepository(seed: [
            LabTestReport(id: UUID(), visitId: UUID(), petId: petId, testName: "Urinalysis", status: .pending,
                          reportFileURL: nil, resultSummary: nil, availableAt: nil),
        ])
        let useCase = GetLabTestReportsUseCase(repository: repo)

        let report = try await useCase.forPet(petId).first
        #expect(report?.status == .pending)
        #expect(report?.reportFileURL == nil)
        #expect(report?.resultSummary == nil)
    }
}
