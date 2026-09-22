import SwiftUI

/// The pet roster + inline "add a pet" composer. Extracted from `ProfileView`
/// per the "one type per file" rule; it still reads/writes the shared
/// `ProfileViewModel` directly since the add-pet field is two-way bound to it.
struct ProfilePetsSection: View {
    @Bindable var viewModel: ProfileViewModel
    let onAddPet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Your pets",
                subtitle: viewModel.pets.isEmpty ? "Add one to start booking" : "\(viewModel.activePets.count) in your care",
                systemImage: "pawprint.fill"
            )

            if viewModel.pets.isEmpty {
                CalloutNote(
                    text: "Add your first pet below — their weight, vaccinations and prescriptions all live in one record the vet can read before arriving.",
                    systemImage: "pawprint.circle.fill"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.pets) { pet in
                            NavigationLink {
                                PetDetailView(pet: pet)
                            } label: {
                                PetCard(pet: pet)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, Spacing.hairline)
                    .padding(.vertical, Spacing.tight)
                }
                // The card row overflows its container horizontally by
                // design; without this the scroll view clips the shadows.
                .scrollClipDisabled()
            }

            AddPetField(
                name: $viewModel.newPetName,
                species: $viewModel.newPetSpecies,
                onAdd: onAddPet
            )
        }
    }
}
