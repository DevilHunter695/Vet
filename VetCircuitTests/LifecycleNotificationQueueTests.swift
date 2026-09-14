import Testing
import Foundation
@testable import VetCircuit

// N3: DrainLifecycleNotificationQueueUseCase — drains the notifications the
// lifecycle-notifications Edge Function queues server-side (sent_at left
// null) through the same J8 push/SMS-fallback pipeline F4/I8/H4 use, then
// marks each row sent. Unlike those three, dedupe is server-side (sent_at)
// rather than a client-local flag, so these tests assert against the fake
// repository's own sent_at state rather than a separate dedupe repository.

private actor FakeAppNotificationRepository: AppNotificationRepository {
    private(set) var stored: [AppNotification]

    init(stored: [AppNotification]) { self.stored = stored }

    func notifications(userId: UUID) async throws -> [AppNotification] {
        stored.filter { $0.userId == userId }
    }

    func markRead(id: UUID) async throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].readAt = .now
    }

    func unsentNotifications(userId: UUID) async throws -> [AppNotification] {
        stored.filter { $0.userId == userId && $0.sentAt == nil }
    }

    func markSent(id: UUID) async throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].sentAt = .now
    }
}

@Suite("DrainLifecycleNotificationQueueUseCase")
struct DrainLifecycleNotificationQueueUseCaseTests {
    private func makeUseCase(repository: FakeAppNotificationRepository, smsRepo: MockSMSFallbackRepository) -> DrainLifecycleNotificationQueueUseCase {
        DrainLifecycleNotificationQueueUseCase(
            repository: repository,
            sendTransactionalNotificationUseCase: SendTransactionalNotificationUseCase(
                pushTokenRepository: MockPushTokenRepository(),
                notificationPreferencesRepository: MockNotificationPreferencesRepository(),
                smsFallbackRepository: smsRepo
            )
        )
    }

    @Test("sends every unsent queued notification and marks it sent")
    func drainsQueuedNotifications() async throws {
        let user = MockData.user
        let vaccination = AppNotification(
            id: UUID(), userId: user.id, category: .vaccinationDue, title: "Vaccination due soon",
            body: "Bruno's rabies shot is due Friday.", sentAt: nil, createdAt: .now.addingTimeInterval(-3600), readAt: nil
        )
        let dormant = AppNotification(
            id: UUID(), userId: user.id, category: .dormantWinback, title: "We miss you and your pet",
            body: "Book a check-up whenever you're ready.", sentAt: nil, createdAt: .now, readAt: nil
        )
        let repository = FakeAppNotificationRepository(stored: [vaccination, dormant])
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(repository: repository, smsRepo: smsRepo)

        let count = try await useCase.execute(user: user)

        #expect(count == 2)
        let remaining = try await repository.unsentNotifications(userId: user.id)
        #expect(remaining.isEmpty)
    }

    @Test("does not re-send a notification that already has sent_at")
    func skipsAlreadySentNotifications() async throws {
        let user = MockData.user
        let alreadySent = AppNotification(
            id: UUID(), userId: user.id, category: .renewalDue, title: "Your plan renews soon",
            body: "Renews Monday.", sentAt: .now.addingTimeInterval(-3600), createdAt: .now.addingTimeInterval(-7200), readAt: nil
        )
        let repository = FakeAppNotificationRepository(stored: [alreadySent])
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(repository: repository, smsRepo: smsRepo)

        let count = try await useCase.execute(user: user)

        #expect(count == 0)
        #expect(await smsRepo.sentRecords.isEmpty)
    }

    @Test("a second drain is a no-op once the queue is empty")
    func secondDrainIsNoOp() async throws {
        let user = MockData.user
        let cart = AppNotification(
            id: UUID(), userId: user.id, category: .abandonedCart, title: "You left something in your cart",
            body: "Finish checkout whenever you're ready.", sentAt: nil, createdAt: .now, readAt: nil
        )
        let repository = FakeAppNotificationRepository(stored: [cart])
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(repository: repository, smsRepo: smsRepo)

        let first = try await useCase.execute(user: user)
        let second = try await useCase.execute(user: user)

        #expect(first == 1)
        #expect(second == 0)
        let records = await smsRepo.sentRecords
        #expect(records.count == 1)
        #expect(records.first?.category == .lifecycleReminder)
    }

    @Test("leaves another user's queued notifications untouched")
    func scopedToTheCurrentUser() async throws {
        let user = MockData.user
        let otherUserNotification = AppNotification(
            id: UUID(), userId: UUID(), category: .vaccinationDue, title: "Vaccination due soon",
            body: "Someone else's pet.", sentAt: nil, createdAt: .now, readAt: nil
        )
        let repository = FakeAppNotificationRepository(stored: [otherUserNotification])
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(repository: repository, smsRepo: smsRepo)

        let count = try await useCase.execute(user: user)

        #expect(count == 0)
        let stillQueued = try await repository.unsentNotifications(userId: otherUserNotification.userId)
        #expect(stillQueued.count == 1)
    }
}
