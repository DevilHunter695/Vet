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
    private var subscriptionToken: AnyObject?

    private let sendChatMessageUseCase = DependencyContainer.shared.sendChatMessageUseCase()
    private let chatRepository = DependencyContainer.shared.chatRepository
    private let visitRepository = DependencyContainer.shared.visitRepository

    init(visitId: UUID) { self.visitId = visitId }

    func load() async {
        do {
            messages = try await chatRepository.history(visitId: visitId)
        } catch {
            errorMessage = error.localizedDescription
        }
        if let visit = try? await visitRepository.visit(id: visitId) {
            isChatOpen = ChatPolicy.isOpen(visit: visit)
        }
        subscriptionToken = chatRepository.subscribe(visitId: visitId) { [weak self] message in
            Task { @MainActor in
                self?.messages.append(message)
                Haptics.soft()
            }
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
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(Color(.secondarySystemBackground))
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Image(systemName: "camera.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .frame(width: 36, height: 36)
                        .background(Theme.primary.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Attach a photo")
                .disabled(!viewModel.isChatOpen)

                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .font(.brandBody)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .accessibilityLabel("Message input")
                    .disabled(!viewModel.isChatOpen)

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
