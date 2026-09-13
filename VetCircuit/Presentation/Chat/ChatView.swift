import SwiftUI
import PhotosUI

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
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Image(systemName: "camera.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .frame(width: 36, height: 36)
                        .background(Theme.primary.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Attach a photo")

                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .font(.brandBody)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .accessibilityLabel("Message input")

                let canSend = !viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
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
