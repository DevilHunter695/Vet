import SwiftUI

@Observable
@MainActor
final class AddressListViewModel {
    var addresses: [Address] = []
    var isLoading = false
    var errorMessage: String?

    private let manageAddressesUseCase = DependencyContainer.shared.manageAddressesUseCase()

    func load(ownerId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            addresses = try await manageAddressesUseCase.list(ownerId: ownerId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func makeDefault(_ address: Address, ownerId: UUID) async {
        do {
            try await manageAddressesUseCase.setDefault(id: address.id, ownerId: ownerId)
            await load(ownerId: ownerId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func remove(_ address: Address) async {
        do {
            try await manageAddressesUseCase.remove(id: address.id)
            addresses.removeAll { $0.id == address.id }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

/// A8: multiple addresses (home/office/parents), with a default and a
/// geofence check against served clusters — a circuit is address-scoped,
/// so this is inventory logic, not just an account nicety.
struct AddressListView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = AddressListViewModel()
    @State private var showingAdd = false

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            // `isLoading` was set and never read, and an empty list rendered
            // as nothing at all.
            if viewModel.isLoading && viewModel.addresses.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    ShimmerView(cornerRadius: Spacing.corner)
                        .frame(height: 56)
                        .listRowBackground(Color.clear)
                }
            } else if viewModel.addresses.isEmpty && viewModel.errorMessage == nil {
                EmptyStateView(
                    systemImage: "mappin.and.ellipse",
                    title: "No addresses yet",
                    message: "A vet comes to you, so we need somewhere to come to. Add your home, office or your parents' place — you pick one when you book.",
                    actionTitle: "Add an address"
                ) {
                    showingAdd = true
                }
                .listRowBackground(Color.clear)
            }
            ForEach(viewModel.addresses) { address in
                AddressRow(address: address) {
                    Haptics.selection()
                    if let user = session.currentUser { Task { await viewModel.makeDefault(address, ownerId: user.id) } }
                }
                if !address.isServed, let user = session.currentUser {
                    WaitlistJoinRow(address: address, userId: user.id)
                }
            }
            .onDelete { indexSet in
                Haptics.warning()
                for index in indexSet { Task { await viewModel.remove(viewModel.addresses[index]) } }
            }
        }
        .animation(Theme.crossFade, value: viewModel.addresses.map(\.id))
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Addresses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Add an address")
            }
        }
        .sheet(isPresented: $showingAdd) {
            if let user = session.currentUser {
                AddAddressView(ownerId: user.id) {
                    Task { await viewModel.load(ownerId: user.id) }
                }
            }
        }
        .task { if let user = session.currentUser { await viewModel.load(ownerId: user.id) } }
    }
}

private struct AddressRow: View {
    let address: Address
    let onMakeDefault: () -> Void

    var body: some View {
        Button(action: onMakeDefault) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: address.isDefault ? "star.fill" : "mappin.circle")
                    .foregroundStyle(address.isDefault ? Theme.warning : Theme.primary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(address.label).font(.brandHeadline).foregroundStyle(.primary)
                        if !address.isServed {
                            TagChip(text: "Not yet covered", tint: Theme.neutral)
                        }
                    }
                    Text(address.line1).font(.brandBody).foregroundStyle(Theme.textSecondary)
                    if let landmark = address.landmark {
                        Text(landmark).font(.brandCaption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// C10: an uncovered address used to just say "Not yet covered" with no
/// action — this closes the loop with a join button and the "N neighbours
/// already waiting" social-proof count (via the `waitlist_count_near` RPC,
/// which returns only a count, never the underlying rows).
@Observable
@MainActor
private final class WaitlistRowViewModel {
    var neighbourCount: Int?
    var hasJoined = false
    var isJoining = false

    private let joinWaitlistUseCase = DependencyContainer.shared.joinWaitlistUseCase()

    func load(address: Address, userId: UUID) async {
        hasJoined = (try? await joinWaitlistUseCase.hasJoined(userId: userId, addressId: address.id)) ?? false
        neighbourCount = try? await joinWaitlistUseCase.neighbourCount(latitude: address.latitude, longitude: address.longitude)
    }

    func join(address: Address, userId: UUID) async {
        isJoining = true
        defer { isJoining = false }
        _ = try? await joinWaitlistUseCase.execute(
            userId: userId, addressId: address.id,
            latitude: address.latitude, longitude: address.longitude, areaLabel: address.label
        )
        hasJoined = true
        neighbourCount = try? await joinWaitlistUseCase.neighbourCount(latitude: address.latitude, longitude: address.longitude)
    }
}

private struct WaitlistJoinRow: View {
    let address: Address
    let userId: UUID
    @State private var viewModel = WaitlistRowViewModel()

    var body: some View {
        HStack {
            if viewModel.hasJoined {
                Label("You're on the waitlist", systemImage: "checkmark.circle.fill")
                    .font(.brandCaption).foregroundStyle(Theme.success)
            } else {
                Button {
                    Haptics.confirm()
                    Task { await viewModel.join(address: address, userId: userId) }
                } label: {
                    if let count = viewModel.neighbourCount, count > 0 {
                        Text("Join the waitlist — \(count) neighbour\(count == 1 ? "" : "s") already waiting")
                    } else {
                        Text("Join the waitlist")
                    }
                }
                .font(.brandCaption)
                .disabled(viewModel.isJoining)
            }
            Spacer()
        }
        .task { await viewModel.load(address: address, userId: userId) }
    }
}

#Preview {
    NavigationStack { AddressListView().environment(SessionStore()) }
}
