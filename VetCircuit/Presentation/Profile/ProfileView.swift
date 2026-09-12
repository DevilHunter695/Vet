import SwiftUI

@Observable
@MainActor
final class ProfileViewModel {
    var pets: [Pet] = []
    var subscription: Subscription?
    var errorMessage: String?
    var newPetName: String = ""
    var newPetSpecies: Pet.Species = .dog
    var loyaltyAccount: LoyaltyAccount?

    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let subscriptionRepository = DependencyContainer.shared.subscriptionRepository
    private let subscribeToPlanUseCase = DependencyContainer.shared.subscribeToPlanUseCase()
    private let getLoyaltyAccountUseCase = DependencyContainer.shared.getLoyaltyAccountUseCase()

    func load(userId: UUID) async {
        do {
            pets = try await managePetsUseCase.list(ownerId: userId)
            subscription = try await subscriptionRepository.currentSubscription(userId: userId)
            loyaltyAccount = try await getLoyaltyAccountUseCase.execute(userId: userId)
            if let subscription, subscription.status == .active {
                PushNotificationManager.shared.scheduleRenewalReminder(subscription: subscription)
            }
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

    func subscribe(userId: UUID, plan: Subscription.PlanType, seatCount: Int = 1) async -> URL? {
        try? await subscribeToPlanUseCase.execute(userId: userId, plan: plan, seatCount: seatCount)
    }
}

struct ProfileView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = ProfileViewModel()
    @State private var checkoutURL: URL?
    @AppStorage("vc.selected_vertical") private var selectedVerticalRaw: String = Vertical.vet.rawValue

    private var selectedVertical: Binding<Vertical> {
        Binding(
            get: { Vertical(rawValue: selectedVerticalRaw) ?? .vet },
            set: { selectedVerticalRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if let user = session.currentUser {
                    Section {
                        HStack(spacing: 14) {
                            PawMascot(size: 56, animated: false)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).font(.brandTitle)
                                if let phone = user.phone {
                                    Text(phone).font(.brandCaption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                    }
                    .appearAnimation()
                }

                Section("Care type") {
                    Picker("Care type", selection: selectedVertical) {
                        ForEach(Vertical.allCases) { vertical in
                            Label(vertical.displayName, systemImage: vertical.systemImage).tag(vertical)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if let loyalty = viewModel.loyaltyAccount {
                    Section("Rewards") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("\(loyalty.points) points", systemImage: "star.circle.fill")
                                    .font(.brandHeadline)
                                    .foregroundStyle(tierColor(loyalty.tier))
                                Spacer()
                                Text(loyalty.tier.rawValue.capitalized)
                                    .font(.brandCaption)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(tierColor(loyalty.tier).opacity(0.15))
                                    .foregroundStyle(tierColor(loyalty.tier))
                                    .clipShape(Capsule())
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 6)
                                    Capsule().fill(tierColor(loyalty.tier))
                                        .frame(width: geo.size.width * tierProgress(loyalty), height: 6)
                                        .animation(Theme.springSoft, value: loyalty.points)
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Subscription") {
                    if let subscription = viewModel.subscription, subscription.status == .active {
                        LabeledContent("Plan", value: subscription.planType.displayName)
                        LabeledContent("Renews", value: subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))
                        if subscription.planType.isBulk {
                            LabeledContent("Seats", value: "\(subscription.seatCount)")
                        }
                    } else {
                        ForEach([Subscription.PlanType.monthly, .quarterly, .annual], id: \.self) { plan in
                            Button("Subscribe — \(plan.displayName)") {
                                Task {
                                    if let user = session.currentUser {
                                        checkoutURL = await viewModel.subscribe(userId: user.id, plan: plan)
                                    }
                                }
                            }
                        }

                        NavigationLink("Corporate / RWA bulk plan") {
                            CorporatePlanView { seatCount in
                                Task {
                                    if let user = session.currentUser {
                                        checkoutURL = await viewModel.subscribe(userId: user.id, plan: .corporate, seatCount: seatCount)
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
                    NavigationLink("Invite friends") {
                        ReferralView()
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

    private func tierColor(_ tier: LoyaltyAccount.Tier) -> Color {
        switch tier {
        case .bronze: return .orange
        case .silver: return .gray
        case .gold: return .yellow
        }
    }

    private func tierProgress(_ account: LoyaltyAccount) -> CGFloat {
        let raw: CGFloat
        switch account.tier {
        case .bronze: raw = CGFloat(account.points) / 200
        case .silver: raw = CGFloat(account.points - 200) / 400
        case .gold: raw = 1
        }
        return min(max(raw, 0), 1)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    ProfileView().environment(SessionStore())
}
