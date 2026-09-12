import SwiftUI

@Observable
@MainActor
final class ProfileViewModel {
    var pets: [Pet] = []
    var subscription: Subscription?
    var errorMessage: String?
    var newPetName: String = ""
    var newPetSpecies: Pet.Species = .dog

    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let subscriptionRepository = DependencyContainer.shared.subscriptionRepository
    private let subscribeToPlanUseCase = DependencyContainer.shared.subscribeToPlanUseCase()

    func load(userId: UUID) async {
        do {
            pets = try await managePetsUseCase.list(ownerId: userId)
            subscription = try await subscriptionRepository.currentSubscription(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPet(ownerId: UUID) async {
        guard !newPetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let pet = Pet(id: UUID(), ownerId: ownerId, name: newPetName, species: newPetSpecies, breed: nil, dateOfBirth: nil)
            let added = try await managePetsUseCase.add(pet)
            pets.append(added)
            newPetName = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePet(_ pet: Pet) async {
        do {
            try await managePetsUseCase.remove(id: pet.id)
            pets.removeAll { $0.id == pet.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func subscribe(userId: UUID, plan: Subscription.PlanType) async -> URL? {
        try? await subscribeToPlanUseCase.execute(userId: userId, plan: plan)
    }
}

struct ProfileView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = ProfileViewModel()
    @State private var checkoutURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if let user = session.currentUser {
                    Section("Account") {
                        LabeledContent("Name", value: user.name)
                        if let phone = user.phone { LabeledContent("Phone", value: phone) }
                    }
                }

                Section("Subscription") {
                    if let subscription = viewModel.subscription, subscription.status == .active {
                        LabeledContent("Plan", value: subscription.planType.rawValue.capitalized)
                        LabeledContent("Renews", value: subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        ForEach([Subscription.PlanType.monthly, .quarterly, .annual], id: \.self) { plan in
                            Button("Subscribe — \(plan.rawValue.capitalized)") {
                                Task {
                                    if let user = session.currentUser {
                                        checkoutURL = await viewModel.subscribe(userId: user.id, plan: plan)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Pets") {
                    ForEach(viewModel.pets) { pet in
                        Text("\(pet.name) · \(pet.species.rawValue.capitalized)")
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet { await viewModel.removePet(viewModel.pets[index]) }
                        }
                    }

                    HStack {
                        TextField("Pet name", text: $viewModel.newPetName)
                        Picker("Species", selection: $viewModel.newPetSpecies) {
                            ForEach(Pet.Species.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        Button("Add") {
                            Task { if let user = session.currentUser { await viewModel.addPet(ownerId: user.id) } }
                        }
                        .disabled(viewModel.newPetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
            }
            .navigationTitle("Profile")
            .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
            .sheet(item: $checkoutURL) { url in
                CheckoutWebView(url: url)
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    ProfileView().environment(SessionStore())
}
