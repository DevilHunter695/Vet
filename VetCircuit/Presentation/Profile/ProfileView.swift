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
            // includeArchived: this list is the pet-management screen, not a
            // booking picker — an archived pet still needs to be visible so
            // its owner can open its record or bring it back (B8).
            pets = try await managePetsUseCase.list(ownerId: userId, includeArchived: true)
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
            withAnimation(Theme.springSoft) { pets.append(added) }
            newPetName = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePet(_ pet: Pet) async {
        do {
            try await managePetsUseCase.remove(id: pet.id)
            withAnimation(Theme.springQuick) { pets.removeAll { $0.id == pet.id } }
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
    @AppStorage("vc.appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

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
                                Text(user.name).font(.brandTitle).brandDisplayText()
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
                    .onChange(of: selectedVerticalRaw) { _, _ in Haptics.selection() }
                }

                Section("Appearance") {
                    Picker("Appearance", selection: appearance) {
                        ForEach(AppearanceOption.allCases) { option in
                            Label(option.displayName, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearanceRaw) { _, _ in Haptics.selection() }
                }

                if let loyalty = viewModel.loyaltyAccount {
                    Section("Rewards") {
                        LoyaltyProgressCard(account: loyalty, color: tierColor(loyalty.tier), progress: tierProgress(loyalty))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Section("Subscription") {
                    if let subscription = viewModel.subscription, subscription.status != .cancelled {
                        LabeledContent("Plan", value: subscription.planType.displayName)
                        LabeledContent("Status", value: subscription.status.rawValue.capitalized)
                        LabeledContent("Renews", value: subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))
                        if subscription.planType.isBulk {
                            LabeledContent("Seats", value: "\(subscription.seatCount)")
                        }
                        NavigationLink("Manage subscription") {
                            ManageSubscriptionView()
                        }
                    } else {
                        ForEach([Subscription.PlanType.monthly, .quarterly, .annual], id: \.self) { plan in
                            Button("Subscribe — \(plan.displayName)") {
                                Haptics.confirm()
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
                .transition(.opacity)
                .animation(Theme.crossFade, value: viewModel.subscription?.id)

                Section {
                    NavigationLink("Addresses") {
                        AddressListView()
                    }
                    NavigationLink("Notifications") {
                        NotificationPreferencesView()
                    }
                    NavigationLink("Privacy & consent") {
                        PrivacyConsentView()
                    }
                    NavigationLink("Notifications centre") {
                        NotificationCenterView()
                    }
                }

                Section("Support & legal") {
                    NavigationLink("Help centre") {
                        HelpCenterView()
                    }
                    NavigationLink("Contact support") {
                        ContactSupportView()
                    }
                    NavigationLink("My tickets") {
                        MyTicketsView()
                    }
                    NavigationLink("Privacy Policy") {
                        PrivacyPolicyView()
                    }
                    NavigationLink("Terms of Service") {
                        TermsOfServiceView()
                    }
                }

                Section("Pets") {
                    ForEach(viewModel.pets) { pet in
                        NavigationLink {
                            PetDetailView(pet: pet)
                        } label: {
                            HStack {
                                Text("\(pet.name) · \(pet.species.rawValue.capitalized)")
                                if pet.isArchived {
                                    Spacer()
                                    Text(pet.archiveReason?.displayName ?? "")
                                        .font(.brandCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        Haptics.warning()
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
                        .onChange(of: viewModel.newPetSpecies) { _, _ in Haptics.selection() }
                        Button("Add") {
                            Haptics.confirm()
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
                        Haptics.warning()
                        Task { await session.signOut() }
                    }
                    .tint(Theme.danger)
                }
            }
            .navigationTitle("Profile")
            .animation(Theme.crossFade, value: viewModel.loyaltyAccount?.points)
            .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
            .sheet(item: $checkoutURL) { url in
                CheckoutWebView(url: url)
            }
        }
    }

    private func tierColor(_ tier: LoyaltyAccount.Tier) -> Color {
        switch tier {
        case .bronze: return Theme.bronzeTier
        case .silver: return Theme.silverTier
        case .gold: return Theme.goldTier
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

private struct LoyaltyProgressCard: View {
    let account: LoyaltyAccount
    let color: Color
    let progress: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(account.points) points", systemImage: "star.circle.fill")
                    .font(.brandHeadline)
                    .foregroundStyle(color)
                Spacer()
                TierBadge(tier: account.tier, color: color)
            }
            ProgressTrack(color: color, progress: progress)
                .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}

private struct TierBadge: View {
    let tier: LoyaltyAccount.Tier
    let color: Color

    var body: some View {
        Text(tier.rawValue.capitalized)
            .font(.brandCaption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct ProgressTrack: View {
    let color: Color
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(color).frame(width: geo.size.width * progress)
            }
        }
        .animation(Theme.springSoft, value: progress)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    ProfileView().environment(SessionStore())
}
