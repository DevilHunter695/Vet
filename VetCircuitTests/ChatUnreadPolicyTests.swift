import Testing
import Foundation
@testable import VetCircuit

// J3: pure unread-count policy tests.

@Suite("ChatUnreadPolicy")
struct ChatUnreadPolicyTests {
    @Test("counts only unread messages from the other party")
    func countsOtherPartyUnread() {
        let me = UUID()
        let vet = UUID()
        let messages = [
            ChatMessage(id: UUID(), visitId: UUID(), senderId: vet, body: "hi", sentAt: .now, readAt: nil),
            ChatMessage(id: UUID(), visitId: UUID(), senderId: vet, body: "hi2", sentAt: .now, readAt: .now),
            ChatMessage(id: UUID(), visitId: UUID(), senderId: me, body: "hey", sentAt: .now, readAt: nil),
        ]
        #expect(ChatUnreadPolicy.unreadCount(messages: messages, viewerId: me) == 1)
    }

    @Test("zero when everything is read or self-sent")
    func zeroWhenAllRead() {
        let me = UUID()
        let messages = [
            ChatMessage(id: UUID(), visitId: UUID(), senderId: me, body: "hey", sentAt: .now, readAt: nil),
            ChatMessage(id: UUID(), visitId: UUID(), senderId: UUID(), body: "hi", sentAt: .now, readAt: .now),
        ]
        #expect(ChatUnreadPolicy.unreadCount(messages: messages, viewerId: me) == 0)
    }
}
