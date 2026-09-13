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
            errorMessage = error.localizedDescription
        }
    }

    func makeDefault(_ address: Address, ownerId: UUID) async {
        do {
            try await manageAddressesUseCase.setDefault(id: address.id, ownerId: ownerId)
            await load(ownerId: ownerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ address: Address) async {
        do {
            try await manageAddressesUseCase.remove(id: address.id)
            addresses.removeAll { $0.id == address.id }
        } catch {
            errorMessage = error.localizedDescription
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
            ForEach(viewModel.addresses) { address in
                AddressRow(address: address) {
                    Haptics.selection()
                    if let user = session.currentUser { Task { await viewModel.makeDefault(address, ownerId: user.id) } }
                }
            }
            .onDelete { indexSet in
                Haptics.warning()
                for index in indexSet { Task { await viewModel.remove(viewModel.addresses[index]) } }
            }
        }
        .animation(Theme.crossFade, value: viewModel.addresses.map(\.id))
        .navigationTitle("Addresses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
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
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(address.label).font(.brandHeadline).foregroundStyle(.primary)
                        if !address.isServed {
                            Text("Not yet covered").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.neutral.opacity(0.15))
                                .foregroundStyle(Theme.neutral)
                                .clipShape(Capsule())
                        }
                    }
                    Text(address.line1).font(.brandBody).foregroundStyle(.secondary)
                    if let landmark = address.landmark {
                        Text(landmark).font(.brandCaption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack { AddressListView().environment(SessionStore()) }
}
