import SwiftUI

@Observable
@MainActor
final class EmergencyViewModel {
    var clinics: [EmergencyClinic] = []
    var isLoading = false
    var errorMessage: String?

    private let listEmergencyClinicsUseCase = DependencyContainer.shared.listEmergencyClinicsUseCase()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            clinics = try await listEmergencyClinicsUseCase.execute()
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

/// C11/L8: the emergency path. VetCircuit is explicitly not an emergency
/// service (plan §L8) — this screen says so up front, then routes the
/// customer to a real 24×7 clinic or the existing symptom-triage flow,
/// rather than leaving "This is urgent" as a dead end.
struct EmergencyView: View {
    @State private var viewModel = EmergencyViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                disclaimer

                NavigationLink {
                    TriageView()
                } label: {
                    HStack {
                        Image(systemName: "stethoscope")
                        Text("Not sure it's an emergency? Run a symptom check")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.brandBody)
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                }
                .buttonStyle(PressableStyle())

                Text("Nearest 24×7 clinics").font(.brandHeadline)

                if viewModel.isLoading && viewModel.clinics.isEmpty {
                    ForEach(0..<2, id: \.self) { _ in ShimmerView().frame(height: 90) }
                } else if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                } else if viewModel.clinics.isEmpty {
                    Text("We couldn't load nearby clinics. If this is life-threatening, call your nearest emergency vet directly.")
                        .font(.brandBody).foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(viewModel.clinics) { clinic in
                        EmergencyClinicCard(clinic: clinic)
                    }
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Emergency")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private var disclaimer: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("VetCircuit is not an emergency service", systemImage: "exclamationmark.triangle.fill")
                    .font(.brandHeadline)
                    .foregroundStyle(Theme.danger)
                Text("We schedule home visits — we can't guarantee an immediate response. If your pet is unconscious, bleeding heavily, struggling to breathe, or in similar danger, call or go to the nearest 24×7 emergency clinic below right away.")
                    .font(.brandBody)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appearAnimation()
    }
}

private struct EmergencyClinicCard: View {
    let clinic: EmergencyClinic

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(clinic.name).font(.brandHeadline)
                    if clinic.isOpen24x7 {
                        Text("24×7").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.success.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.success)
                    }
                }
                Text(clinic.address).font(.brandCaption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    if let telURL = clinic.telURL {
                        Link(destination: telURL) {
                            Label("Call", systemImage: "phone.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.danger)
                    }
                    if let mapsURL = clinic.mapsURL {
                        Link(destination: mapsURL) {
                            Label("Directions", systemImage: "map.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack { EmergencyView() }
}
