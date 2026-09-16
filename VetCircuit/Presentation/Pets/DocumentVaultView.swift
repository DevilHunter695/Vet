import SwiftUI
import UniformTypeIdentifiers

/// B6: document vault — prior vet reports / insurance documents uploaded
/// against a pet. Reachable from `PetDetailView`.
@Observable
@MainActor
final class DocumentVaultViewModel {
    let pet: Pet
    var documents: [PetDocument] = []
    var errorMessage: String?
    var isUploading = false

    private let useCase = DependencyContainer.shared.managePetDocumentsUseCase()

    init(pet: Pet) { self.pet = pet }

    func load() async {
        do {
            documents = try await useCase.list(petId: pet.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `title` defaults to the picked file's name when the caller doesn't
    /// prompt for one — kept simple since there's no real Storage upload yet
    /// (see `MockPetDocumentRepository`/`SupabasePetDocumentRepository`).
    func upload(title: String, data: Data) async {
        isUploading = true
        defer { isUploading = false }
        do {
            let uploaderId = await DependencyContainer.shared.authRepository.currentUser()?.id ?? pet.ownerId
            let document = try await useCase.upload(petId: pet.id, uploaderId: uploaderId, title: title, data: data)
            withAnimation(Theme.springSoft) { documents.insert(document, at: 0) }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ document: PetDocument) async {
        do {
            try await useCase.delete(id: document.id)
            withAnimation(Theme.springSoft) { documents.removeAll { $0.id == document.id } }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DocumentVaultView: View {
    @State private var viewModel: DocumentVaultViewModel
    @State private var showingImporter = false
    @State private var pendingTitle = ""
    @State private var pendingData: Data?
    @State private var showingTitlePrompt = false

    init(pet: Pet) {
        _viewModel = State(initialValue: DocumentVaultViewModel(pet: pet))
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
                    .listRowSeparator(.hidden)
            }

            if viewModel.documents.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text.image",
                    title: "No documents yet",
                    message: "Upload prior vet reports or insurance papers so they're on hand for a boarding stay, travel, or a new clinic.",
                    actionTitle: "Upload a document"
                ) { showingImporter = true }
                .listRowSeparator(.hidden)
            } else {
                ForEach(viewModel.documents) { document in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title).font(.brandBody)
                        Text(document.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(document) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Document vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(viewModel.isUploading)
            }
        }
        .task { await viewModel.load() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image, .plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                loadPickedFile(url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .alert("Name this document", isPresented: $showingTitlePrompt) {
            TextField("Title", text: $pendingTitle)
            Button("Upload") {
                if let data = pendingData {
                    Task { await viewModel.upload(title: pendingTitle, data: data) }
                }
                pendingData = nil
                pendingTitle = ""
            }
            Button("Cancel", role: .cancel) {
                pendingData = nil
                pendingTitle = ""
            }
        }
    }

    private func loadPickedFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.errorMessage = "Couldn't read that file."
            return
        }
        pendingData = data
        pendingTitle = url.deletingPathExtension().lastPathComponent
        showingTitlePrompt = true
    }
}

#Preview {
    NavigationStack { DocumentVaultView(pet: MockData.user.pets.first ?? Pet(id: UUID(), ownerId: UUID(), name: "Bruno", species: .dog, breed: "Labrador", dateOfBirth: nil)) }
}
