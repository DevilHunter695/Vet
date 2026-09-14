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
            errorMessage = error.localizedDescription
        }
    }

    func createHousehold(name: String, ownerId: UUID) async {
        do {
            household = try await manageHouseholdUseCase.create(name: name, ownerId: ownerId)
            await load(userId: ownerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func invite(userId: UUID) async {
        guard let household else { return }
        do {
            let member = try await manageHouseholdUseCase.invite(householdId: household.id, phone: invitePhone)
            withAnimation(Theme.springSoft) { members.append(member) }
            invitePhone = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ member: HouseholdMember) async {
        guard let household else { return }
        do {
            try await manageHouseholdUseCase.removeMember(householdId: household.id, memberId: member.id)
            withAnimation(Theme.springQuick) { members.removeAll { $0.id == member.id } }
        } catch {
            errorMessage = error.localizedDescription
        }
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
                            VStack(alignment: .leading) {
                                Text(member.invitedPhone ?? "Member").font(.brandBody)
                                if member.invitedPhone != nil {
                                    Text("Invited — pending").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(member.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
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
                            Text(pet.name).font(.brandBody)
                        }
                    }
                }

                if !viewModel.sharedVisits.isEmpty {
                    Section("Household bookings") {
                        ForEach(viewModel.sharedVisits) { visit in
                            VStack(alignment: .leading) {
                                Text(visit.scheduledAt, style: .date).font(.brandBody)
                                Text(visit.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Invite by phone") {
                    HStack {
                        TextField("Phone number", text: $viewModel.invitePhone)
                            .keyboardType(.phonePad)
                        Button("Invite") {
                            Haptics.confirm()
                            Task { if let user = session.currentUser { await viewModel.invite(userId: user.id) } }
                        }
                        .disabled(viewModel.invitePhone.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Button(viewModel.currentUserIsOwner ? "Delete household" : "Leave household", role: .destructive) {
                        Haptics.warning()
                        if let user = session.currentUser,
                           let mine = viewModel.members.first(where: { $0.userId == user.id }) {
                            Task { await viewModel.remove(mine) }
                        }
                    }
                }
            } else if viewModel.isLoading {
                ProgressView()
            } else {
                Section("Start a household") {
                    Text("Invite a spouse or family member to see and book for the same pets.")
                        .font(.brandCaption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Household name (e.g. \"The Sharmas\")", text: $newHouseholdName)
                        Button("Create") {
                            Haptics.confirm()
                            Task { if let user = session.currentUser { await viewModel.createHousehold(name: newHouseholdName, ownerId: user.id) } }
                        }
                        .disabled(newHouseholdName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .navigationTitle("Household")
        .task {
            if let user = session.currentUser {
                viewModel.setCurrentUser(user.id)
                await viewModel.load(userId: user.id)
            }
        }
    }
}

#Preview {
    NavigationStack { HouseholdView().environment(SessionStore()) }
}
