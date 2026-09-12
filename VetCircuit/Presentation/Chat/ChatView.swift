import SwiftUI

@Observable
@MainActor
final class ChatViewModel {
    let visitId: UUID
    var messages: [ChatMessage] = []
    var draft: String = ""
    var errorMessage: String?
    private var subscriptionToken: AnyObject?

    private let sendChatMessageUseCase = DependencyContainer.shared.sendChatMessageUseCase()
    private let chatRepository = DependencyContainer.shared.chatRepository

    init(visitId: UUID) { self.visitId = visitId }

    func load() async {
        do {
            messages = try await chatRepository.history(visitId: visitId)
        } catch {
            errorMessage = error.localizedDescription
        }
        subscriptionToken = chatRepository.subscribe(visitId: visitId) { [weak self] message in
            Task { @MainActor in self?.messages.append(message) }
        }
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
}

struct ChatView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel: ChatViewModel

    init(visitId: UUID) { _viewModel = State(initialValue: ChatViewModel(visitId: visitId)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.messages) { message in
                            ChatBubble(message: message, isMine: message.senderId == session.currentUser?.id)
                                .id(message.id)
                        }
                    }
                    .padding()
                    .animation(Theme.springQuick, value: viewModel.messages.count)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
                        withAnimation(Theme.springQuick) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage).padding(.horizontal)
            }

            HStack(spacing: 10) {
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .font(.brandBody)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .accessibilityLabel("Message input")

                let canSend = !viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.gray.opacity(0.4)))
                        .clipShape(Circle())
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
        .task { await viewModel.load() }
    }
}

#Preview {
    NavigationStack { ChatView(visitId: UUID()).environment(SessionStore()) }
}
