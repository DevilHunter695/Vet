import Testing
import Foundation
@testable import VetCircuit

// E9/M4/M5 domain-layer tests: pure Swift logic plus the mock repositories,
// no UI or network.

@Suite("ManageSavedPaymentMethodsUseCase (E9)")
struct SavedPaymentMethodsUseCaseTests {
    @Test("saving requires a non-empty gateway token")
    func rejectsEmptyToken() async throws {
        let useCase = ManageSavedPaymentMethodsUseCase(repository: MockSavedPaymentMethodRepository())
        await #expect(throws: DomainError.self) {
            try await useCase.save(userId: UUID(), gatewayTokenId: "  ", displayLabel: "Visa •••• 4242")
        }
    }

    @Test("the first saved method becomes default automatically")
    func firstMethodIsDefault() async throws {
        let userId = UUID()
        let useCase = ManageSavedPaymentMethodsUseCase(repository: MockSavedPaymentMethodRepository())
        let method = try await useCase.save(userId: userId, gatewayTokenId: "tok_abc", displayLabel: "Visa •••• 1111")
        #expect(method.isDefault)
    }

    @Test("setting a new default clears the previous one")
    func settingDefaultClearsOthers() async throws {
        let userId = UUID()
        let useCase = ManageSavedPaymentMethodsUseCase(repository: MockSavedPaymentMethodRepository())
        let first = try await useCase.save(userId: userId, gatewayTokenId: "tok_1", displayLabel: "Visa •••• 1111")
        let second = try await useCase.save(userId: userId, gatewayTokenId: "tok_2", displayLabel: "Mastercard •••• 2222")
        try await useCase.setDefault(id: second.id, userId: userId)
        let all = try await useCase.list(userId: userId)
        #expect(all.first { $0.id == second.id }?.isDefault == true)
        #expect(all.first { $0.id == first.id }?.isDefault == false)
    }

    @Test("removing a method drops it from the list")
    func removeDropsMethod() async throws {
        let userId = UUID()
        let useCase = ManageSavedPaymentMethodsUseCase(repository: MockSavedPaymentMethodRepository())
        let method = try await useCase.save(userId: userId, gatewayTokenId: "tok_1", displayLabel: "Visa •••• 1111")
        try await useCase.remove(id: method.id)
        let all = try await useCase.list(userId: userId)
        #expect(!all.contains { $0.id == method.id })
    }
}

@Suite("IssueSupportRefundUseCase (M4)")
struct IssueSupportRefundUseCaseTests {
    private func makeUseCase() -> IssueSupportRefundUseCase {
        IssueSupportRefundUseCase(repository: MockSupportRefundAuditRepository(refundRepository: MockRefundRepository()))
    }

    @Test("rejects a zero or negative amount")
    func rejectsNonPositiveAmount() async throws {
        let useCase = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.execute(ticketId: UUID(), visitId: UUID(), issuedByUserId: UUID(), kind: .refund, amountMinorUnits: 0, reason: "test")
        }
    }

    @Test("rejects a blank reason")
    func rejectsBlankReason() async throws {
        let useCase = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.execute(ticketId: UUID(), visitId: UUID(), issuedByUserId: UUID(), kind: .refund, amountMinorUnits: 5000, reason: "   ")
        }
    }

    @Test("a refund kind records the linked refund id in the audit trail")
    func refundKindLinksRefund() async throws {
        let useCase = makeUseCase()
        let ticketId = UUID()
        let audit = try await useCase.execute(ticketId: ticketId, visitId: UUID(), issuedByUserId: UUID(), kind: .refund, amountMinorUnits: 1500, reason: "Vet no-show")
        #expect(audit.kind == .refund)
        #expect(audit.refundId != nil)
        #expect(audit.walletLedgerEntryId == nil)
    }

    @Test("a wallet credit kind does not create a refund id")
    func walletCreditKindHasNoRefund() async throws {
        let useCase = makeUseCase()
        let audit = try await useCase.execute(ticketId: UUID(), visitId: UUID(), issuedByUserId: UUID(), kind: .walletCredit, amountMinorUnits: 500, reason: "Goodwill credit")
        #expect(audit.kind == .walletCredit)
        #expect(audit.refundId == nil)
        #expect(audit.walletLedgerEntryId != nil)
    }

    @Test("the audit trail is scoped to its ticket")
    func auditTrailScopedToTicket() async throws {
        let useCase = makeUseCase()
        let ticketA = UUID()
        let ticketB = UUID()
        _ = try await useCase.execute(ticketId: ticketA, visitId: UUID(), issuedByUserId: UUID(), kind: .refund, amountMinorUnits: 1000, reason: "reason A")
        _ = try await useCase.execute(ticketId: ticketB, visitId: UUID(), issuedByUserId: UUID(), kind: .walletCredit, amountMinorUnits: 2000, reason: "reason B")
        let trailA = try await useCase.auditTrail(ticketId: ticketA)
        #expect(trailA.count == 1)
        #expect(trailA.allSatisfy { $0.ticketId == ticketA })
    }
}

@Suite("BusinessHoursPolicy and ContactSupportByCallUseCase (M5)")
struct BusinessHoursCallSupportTests {
    private static let ist = TimeZone(identifier: "Asia/Kolkata")!

    private func istDate(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.ist
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 15
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    @Test("9am IST is reachable")
    func openingHourIsReachable() {
        #expect(BusinessHoursPolicy.isReachableByPhone(at: istDate(hour: 9)))
    }

    @Test("8:59am IST is not reachable")
    func justBeforeOpeningIsNotReachable() {
        #expect(!BusinessHoursPolicy.isReachableByPhone(at: istDate(hour: 8, minute: 59)))
    }

    @Test("8:59pm IST is reachable")
    func justBeforeClosingIsReachable() {
        #expect(BusinessHoursPolicy.isReachableByPhone(at: istDate(hour: 20, minute: 59)))
    }

    @Test("9pm IST is closed (exclusive upper bound)")
    func closingHourIsNotReachable() {
        #expect(!BusinessHoursPolicy.isReachableByPhone(at: istDate(hour: 21)))
    }

    @Test("midnight IST is closed")
    func midnightIsNotReachable() {
        #expect(!BusinessHoursPolicy.isReachableByPhone(at: istDate(hour: 0)))
    }

    @Test("use case returns a tel: URL during business hours")
    func returnsCallURLDuringBusinessHours() {
        let useCase = ContactSupportByCallUseCase(supportPhoneNumber: "+911800123456")
        let outcome = useCase.execute(at: istDate(hour: 14))
        guard case .callURL(let url) = outcome else {
            Issue.record("expected a call URL")
            return
        }
        #expect(url.absoluteString == "tel:+911800123456")
    }

    @Test("use case falls back outside business hours")
    func fallsBackOutsideBusinessHours() {
        let useCase = ContactSupportByCallUseCase(supportPhoneNumber: "+911800123456")
        let outcome = useCase.execute(at: istDate(hour: 22))
        #expect(outcome == .outsideBusinessHours)
    }
}
