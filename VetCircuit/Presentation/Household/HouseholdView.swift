import SwiftUI

@Observable
@MainActor
final class HouseholdViewModel {
    var household: Household?
    var members: [HouseholdMember] = []
    /// A9: every pet owned by anyone in the household, not just the caller's
    /// own — populated via `ManageHouseholdUseCase.sharedPets`.
    var sharedPets: [Pet] = []
    /// A9: bookings across every shared pet — the "book for" half of the row.
    var sharedVisits: [Visit] = []
    var invitePhone: String = ""
    var errorMessage: String?
    var isLoading = false

    private let manageHouseholdUseCase = DependencyContainer.shared.manageHouseholdUseCase()

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            household = try await manageHouseholdUseCase.current(userId: userId)
            if household != nil {
                async let membersTask = manageHouseholdUseCase.members(householdId: household!.id)
                async let petsTask = manageHouseholdUseCase.sharedPets(userId: userId)
                async let visitsTask = manageHouseholdUseCase.sharedVisits(userId: userId)
                (members, sharedPets, sharedVisits) = try await (membersTask, petsTask, visitsTask)
            } else {
                sharedPets = []
                sharedVisits = []
            }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func createHousehold(name: String, ownerId: UUID) async {
        do {
            household = try await manageHouseholdUseCase.create(name: name, ownerId: ownerId)
            await load(userId: ownerId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func invite(userId: UUID) async {
        guard let household else { return }
        do {
            let member = try await manageHouseholdUseCase.invite(householdId: household.id, phone: invitePhone)
            withAnimation(Theme.springSoft) { members.append(member) }
            invitePhone = ""
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func remove(_ member: HouseholdMember) async {
        guard let household else { return }
        do {
            try await manageHouseholdUseCase.removeMember(householdId: household.id, memberId: member.id)
            withAnimation(Theme.springQuick) { members.removeAll { $0.id == member.id } }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// A9: a member invited by phone hasn't been reconciled to the caller's
    /// real user id yet, so matching on `userId` alone found nothing and
    /// "Leave household" quietly did nothing. Fall back to the phone number.
    func myMembership(userId: UUID, phone: String?) -> HouseholdMember? {
        if let byId = members.first(where: { $0.userId == userId }) { return byId }
        guard let phone else { return nil }
        let digits = Self.digits(phone)
        guard !digits.isEmpty else { return nil }
        return members.first { member in
            guard let invited = member.invitedPhone else { return false }
            let other = Self.digits(invited)
            return !other.isEmpty && (other.hasSuffix(digits) || digits.hasSuffix(other))
        }
    }

    private static func digits(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    /// Names the pet a household booking is for — "a booking on Tuesday" is
    /// useless when four people share five animals.
    func petName(for visit: Visit) -> String {
        sharedPets.first { $0.id == visit.petId }?.name ?? "Household pet"
    }

    var currentUserIsOwner: Bool {
        guard let household else { return false }
        return household.ownerId == currentUserId
    }
    private var currentUserId: UUID?
    func setCurrentUser(_ id: UUID) { currentUserId = id }
}

/// A9: invite a spouse/family member so they can see and book for the same
/// pets. See the modeling-decision comment on `Household`
/// (Domain/Models/HouseholdModels.swift) for why pet ownership itself is
/// untouched — this view only manages who's *in* the household.
struct HouseholdView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = HouseholdViewModel()
    @State private var newHouseholdName = ""
    @State private var pendingLeave: HouseholdMember?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            if let household = viewModel.household {
                Section {
                    LabeledContent("Household", value: household.name)
                }

                Section("Members") {
                    ForEach(viewModel.members) { member in
                        HStack {
                            Image(systemName: member.role == .owner ? "star.fill" : "person.fill")
                                .foregroundStyle(member.role == .owner ? Theme.warning : Theme.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.invitedPhone ?? "Member").font(.brandBody)
                                Text(member.invitedPhone != nil
                                     ? "Invited — waiting for them to join"
                                     : (member.role == .owner
                                        ? "Owns this household and its pets"
                                        : "Can see and book for shared pets"))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            TagChip(
                                text: member.role == .owner ? "Owner" : "Member",
                                systemImage: member.role == .owner ? "star.fill" : "person.fill",
                                tint: member.role == .owner ? Theme.warning : Theme.primary
                            )
                        }
                    }
                    .onDelete { indexSet in
                        Haptics.warning()
                        for index in indexSet { Task { await viewModel.remove(viewModel.members[index]) } }
                    }
                }

                if !viewModel.sharedPets.isEmpty {
                    Section("Shared pets") {
                        ForEach(viewModel.sharedPets) { pet in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pet.name).font(.brandBody)
                                    if let breed = pet.breed, !breed.isEmpty {
                                        Text(breed).font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                TagChip(text: pet.species.displayName, systemImage: pet.species.symbolName)
                            }
                        }
                    }
                }

                if !viewModel.sharedVisits.isEmpty {
                    Section("Household bookings") {
                        ForEach(viewModel.sharedVisits) { visit in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    // "A booking" means nothing in a shared
                                    // household — whose pet is the point.
                                    Text(viewModel.petName(for: visit)).font(.brandBody)
                                    Text(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: 8)
                                // Was `rawValue.capitalized` — "Enroute".
                                StatusBadge(status: visit.status)
                            }
                        }
                    }
                }

                Section("Invite by phone") {
                    HStack {
                        TextField("Phone number", text: $viewModel.invitePhone)
                            .keyboardType(.phonePad)
                            // Lets the system offer a number from Contacts
                            // rather than making somebody read it off another
                            // screen and retype it.
                            .textContentType(.telephoneNumber)
                        Button("Invite") {
                            Haptics.confirm()
                            Task { if let user = session.currentUser { await viewModel.invite(userId: user.id) } }
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.primary)
                        .disabled(viewModel.invitePhone.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Button(viewModel.currentUserIsOwner ? "Delete household" : "Leave household", role: .destructive) {
                        Haptics.warning()
                        guard let user = session.currentUser else { return }
                        // `HouseholdMember.userId` is non-optional, so an
                        // invited-but-not-yet-joined row is created with a
                        // fresh placeholder UUID (see the mock's invite path).
                        // That placeholder never equals the invitee's real
                        // user id, so once they actually opened the app and
                        // tapped "Leave household", matching on id alone found
                        // nothing and the button did nothing at all. The phone
                        // fallback is what makes their own row findable.
                        if let mine = viewModel.myMembership(userId: user.id, phone: user.phone) {
                            pendingLeave = mine
                        } else {
                            viewModel.errorMessage = "Couldn't find your membership here. Pull to refresh, or contact support."
                        }
                    }
                }
            } else if viewModel.isLoading {
                ProgressView()
            } else {
                Section("Start a household") {
                    Text("Invite a spouse or family member to see and book for the same pets.")
                        .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                    HStack {
                        TextField("Household name (e.g. \"The Sharmas\")", text: $newHouseholdName)
                            .textInputAutocapitalization(.words)
                        Button("Create") {
                            Haptics.confirm()
                            Task { if let user = session.currentUser { await viewModel.createHousehold(name: newHouseholdName, ownerId: user.id) } }
                        }
                        .disabled(newHouseholdName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Household")
        .confirmationDialog(
            viewModel.currentUserIsOwner ? "Delete this household?" : "Leave this household?",
            isPresented: Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } }),
            titleVisibility: .visible
        ) {
            Button(viewModel.currentUserIsOwner ? "Delete household" : "Leave household", role: .destructive) {
                guard let member = pendingLeave else { return }
                pendingLeave = nil
                Task { await viewModel.remove(member) }
            }
            Button("Stay", role: .cancel) { pendingLeave = nil }
        } message: {
            Text(viewModel.currentUserIsOwner
                 ? "Everyone loses the shared pets and bookings. Your own stay with you."
                 : "You'll stop seeing this household's shared pets and bookings.")
        }
        .task {
            if let user = session.currentUser {
                viewModel.setCurrentUser(user.id)
                await viewModel.load(userId: user.id)
            }
        }
        // The error copy on this screen tells people to pull to refresh.
        // It did not have a refresh gesture, so that sentence was an
        // instruction to do something impossible — worse than saying
        // nothing, because it reads as the user failing rather than the app.
        .refreshable {
            if let user = session.currentUser {
                await viewModel.load(userId: user.id)
            }
        }
    }
}

#Preview {
    NavigationStack { HouseholdView().environment(SessionStore()) }
}
