import SwiftUI
import PhotosUI

/// A5: edit profile — name, email, photo, language. Deliberately scoped to
/// plain profile fields; it never touches identity (Sign in with Apple,
/// phone OTP, the session) or `User.phone`, which is set only by those flows.
@Observable
@MainActor
final class EditProfileViewModel {
    var name: String = ""
    var email: String = ""
    var language: String = ""
    var photoURL: URL?
    var isSaving = false
    var errorMessage: String?

    private let editProfileUseCase = DependencyContainer.shared.editProfileUseCase()

    func load(from user: User) {
        name = user.name
        email = user.email ?? ""
        language = user.preferredLanguage ?? ""
        photoURL = user.photoURL
    }

    func save(currentUser: User) async -> User? {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await editProfileUseCase.updateProfile(
                currentUser, name: name, email: email, language: language.isEmpty ? nil : language
            )
            Haptics.success()
            return updated
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updatePhoto(userId: UUID, data: Data) async -> User? {
        do {
            let updated = try await editProfileUseCase.updatePhoto(userId: userId, data: data)
            photoURL = updated.photoURL
            Haptics.success()
            return updated
        } catch {
            errorMessage = "Couldn't upload that photo."
            return nil
        }
    }
}

struct EditProfileView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = EditProfileViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?

    /// A5's notes mention language as a profile-level preference; these
    /// mirror the language list `Vet` filtering already uses (plan §C3) so
    /// the picker isn't inventing a new, disconnected taxonomy.
    private static let languageOptions = ["", "English", "Hindi", "Kannada", "Tamil", "Telugu", "Marathi"]

    var body: some View {
        Form {
            Section {
                HStack {
                    if let photoURL = viewModel.photoURL {
                        AsyncImage(url: photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color(.tertiarySystemFill))
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Circle().fill(Color(.tertiarySystemFill))
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                    }
                    // Same reason as PetDetailView: PhotosPicker's label
                    // closure is Sendable-checked, so the main-actor view
                    // model can't be read from inside it.
                    let photoButtonTitle = viewModel.photoURL == nil ? "Add photo" : "Change photo"
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Text(photoButtonTitle)
                            .font(.brandCaption)
                    }
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        guard let newItem, let data = try? await newItem.loadTransferable(type: Data.self),
                              let user = session.currentUser else { return }
                        if let updated = await viewModel.updatePhoto(userId: user.id, data: data) {
                            session.currentUser = updated
                        }
                    }
                }
            }

            Section("Name & email") {
                TextField("Name", text: $viewModel.name)
                    .textContentType(.name)
                TextField("Email", text: $viewModel.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Preferred language") {
                Picker("Language", selection: $viewModel.language) {
                    ForEach(Self.languageOptions, id: \.self) { option in
                        Text(option.isEmpty ? "Not set" : option).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(Theme.danger).font(.brandCaption)
                }
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard let user = session.currentUser else { return }
                        if let updated = await viewModel.save(currentUser: user) {
                            session.currentUser = updated
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.name.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSaving)
            }
        }
        .onAppear {
            if let user = session.currentUser { viewModel.load(from: user) }
        }
    }
}

#Preview {
    NavigationStack { EditProfileView() }.environment(SessionStore())
}
