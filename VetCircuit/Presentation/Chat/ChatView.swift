import SwiftUI
import PhotosUI

@Observable
@MainActor
final class ChatViewModel {
    let visitId: UUID
    var messages: [ChatMessage] = []
    var draft: String = ""
    var errorMessage: String?
    /// J5: nil while the visit is still loading; once known, gates the
    /// input bar and shows the "chat has closed" banner.
    var isChatOpen: Bool = true
    /// J3: set briefly whenever the other party sends a typing ping.
    var otherPartyIsTyping: Bool = false
    private var subscriptionToken: AnyObject?
    private var typingSubscriptionToken: AnyObject?
    private var typingDismissTask: Task<Void, Never>?
    private var currentUserId: UUID?

    private let sendChatMessageUseCase = DependencyContainer.shared.sendChatMessageUseCase()
    private let chatRepository = DependencyContainer.shared.chatRepository
    private let visitRepository = DependencyContainer.shared.visitRepository

    /// J3: unread count for whoever is *not* `currentUserId` — used by a
    /// visit-list row to show a chat badge without opening the thread.
    var unreadCount: Int {
        guard let currentUserId else { return 0 }
        return ChatUnreadPolicy.unreadCount(messages: messages, viewerId: currentUserId)
    }

    init(visitId: UUID) { self.visitId = visitId }

    func load(currentUserId: UUID) async {
        self.currentUserId = currentUserId
        do {
            messages = try await chatRepository.history(visitId: visitId)
        } catch {
            errorMessage = error.localizedDescription
        }
        // J3: read receipts — mark the other party's messages read as soon
        // as this thread is opened.
        try? await chatRepository.markRead(visitId: visitId, readerId: currentUserId)
        if let visit = try? await visitRepository.visit(id: visitId) {
            isChatOpen = ChatPolicy.isOpen(visit: visit)
        }
        subscriptionToken = chatRepository.subscribe(visitId: visitId) { [weak self] message in
            Task { @MainActor in
                self?.messages.append(message)
                Haptics.soft()
                if let self, let currentUserId = self.currentUserId, message.senderId != currentUserId {
                    try? await self.chatRepository.markRead(visitId: self.visitId, readerId: currentUserId)
                }
            }
        }
        typingSubscriptionToken = chatRepository.subscribeToTyping(visitId: visitId) { [weak self] senderId in
            Task { @MainActor in
                guard let self, senderId != self.currentUserId else { return }
                self.otherPartyIsTyping = true
                self.typingDismissTask?.cancel()
                self.typingDismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { self.otherPartyIsTyping = false }
                }
            }
        }
    }

    /// J3: called as the customer types — a lightweight, unstored ping so
    /// the other side can show "…is typing".
    func notifyTyping() {
        guard let currentUserId else { return }
        Task { await chatRepository.sendTypingIndicator(visitId: visitId, senderId: currentUserId) }
    }

    func send() async {
        let body = draft
        draft = ""
        do {
            let message = try await sendChatMessageUseCase.execute(visitId: visitId, body: body)
            messages.append(message)
        } catch {
            errorMessage = error.localizedDescription
            draft = body
        }
    }

    func sendPhoto(_ imageData: Data) async {
        do {
            let message = try await sendChatMessageUseCase.sendPhoto(visitId: visitId, imageData: imageData)
            Haptics.confirm()
            messages.append(message)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

struct ChatView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel: ChatViewModel
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showingContactSupport = false

    init(visitId: UUID) { _viewModel = State(initialValue: ChatViewModel(visitId: visitId)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.messages) { message in
                            let isMine = message.senderId == session.currentUser?.id
                            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                                ChatBubble(message: message, isMine: isMine)
                                // J3: read receipt — shown only on the sender's own bubbles.
                                if isMine && message.readAt != nil {
                                    Text("Read").font(.caption2).foregroundStyle(Theme.textSecondary).padding(.trailing, 4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
                            .accessibilityElement(children: .combine)
                            .id(message.id)
                        }
                        if viewModel.otherPartyIsTyping {
                            HStack {
                                Text("Typing…").font(.brandCaption).foregroundStyle(Theme.textSecondary).italic()
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .animation(Theme.springQuick, value: viewModel.messages.count)
                }
                .auroraScreenBackground()
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
                        withAnimation(Theme.springQuick) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage).padding(.horizontal)
            }

            if !viewModel.isChatOpen {
                // J5: chat auto-closes 48h post-visit — this stops unpaid
                // consulting over chat and routes anything real to support.
                Button {
                    Haptics.tap()
                    showingContactSupport = true
                } label: {
                    Label("This chat has closed — need help? Contact support", systemImage: "lock.fill")
                        .font(.brandCaption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(Color(.secondarySystemBackground))
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    // The circle stays 36pt; the touch target around it is
                    // 44pt, which is the part the finger actually needs.
                    Image(systemName: "camera.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .frame(width: 36, height: 36)
                        .background(Theme.primary.opacity(0.1), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Attach a photo")
                .disabled(!viewModel.isChatOpen)

                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .font(.brandBody)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .accessibilityLabel("Message input")
                    .disabled(!viewModel.isChatOpen)
                    .onChange(of: viewModel.draft) { _, _ in viewModel.notifyTyping() }

                let canSend = viewModel.isChatOpen && !viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
                Button {
                    Haptics.tap()
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.gray.opacity(0.4)))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend)
                .animation(Theme.springQuick, value: canSend)
                .accessibilityLabel("Send message")
            }
            .padding()
            .background(.regularMaterial)
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(currentUserId: session.currentUser?.id ?? UUID()) }
        .sheet(isPresented: $showingContactSupport) {
            ContactSupportView(visitId: viewModel.visitId)
        }
        .onChange(of: photoPickerItem) { _, newItem in
            Task {
                guard let newItem, let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                await viewModel.sendPhoto(data)
                photoPickerItem = nil
            }
        }
    }
}

#Preview {
    NavigationStack { ChatView(visitId: UUID()).environment(SessionStore()) }
}
