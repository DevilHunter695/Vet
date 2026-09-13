import SwiftUI

@Observable
@MainActor
final class TriageViewModel {
    var species: Pet.Species = .dog
    var symptoms: String = ""
    var result: TriageResult?
    var isLoading = false
    var errorMessage: String?

    private let runTriageUseCase = DependencyContainer.shared.runTriageUseCase()

    func assess() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            withAnimation(Theme.springQuick) { result = nil }
            let outcome = try await runTriageUseCase.execute(species: species, symptoms: symptoms)
            withAnimation(Theme.springSoft) { result = outcome }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// V3: quick, chat-style pre-triage before committing to book a visit.
/// Not a diagnosis — routes to "book now", "book soon", or self-care.
struct TriageView: View {
    @State private var viewModel = TriageViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        PawMascot(size: 44, animated: false)
                        Text("Tell us what's going on").font(.brandTitle).brandDisplayText()
                    }
                    Text("This isn't a diagnosis — it helps us point you to the right next step.")
                        .font(.brandBody)
                        .foregroundStyle(.secondary)
                }
                .appearAnimation()

                Picker("Pet type", selection: $viewModel.species) {
                    ForEach(Pet.Species.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("e.g. Not eating since yesterday, seems tired", text: $viewModel.symptoms, axis: .vertical)
                    .font(.brandBody)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .lineLimit(3...6)

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                PrimaryButton(title: "Check symptoms", isLoading: viewModel.isLoading) {
                    Task { await viewModel.assess() }
                }

                if let result = viewModel.result {
                    TriageResultCard(result: result)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Symptom check")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TriageResultCard: View {
    let result: TriageResult

    private var accent: Color {
        switch result.recommendation {
        case .bookVisitUrgently: return .red
        case .bookVisit: return .orange
        case .selfCare: return .green
        }
    }

    private var icon: String {
        switch result.recommendation {
        case .bookVisitUrgently: return "exclamationmark.triangle.fill"
        case .bookVisit: return "stethoscope"
        case .selfCare: return "checkmark.seal.fill"
        }
    }

    private var title: String {
        switch result.recommendation {
        case .bookVisitUrgently: return "Book a visit now"
        case .bookVisit: return "Consider booking a visit"
        case .selfCare: return "Likely okay to monitor at home"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(accent.opacity(0.15))
                        Image(systemName: icon).foregroundStyle(accent)
                    }
                    .frame(width: 36, height: 36)
                    Text(title).font(.brandHeadline).foregroundStyle(accent)
                }
                Text(result.message)
                    .font(.brandBody)
                    .foregroundStyle(.secondary)

                if result.recommendation != .selfCare {
                    NavigationLink {
                        CircuitsListView()
                    } label: {
                        Text("Browse circuits to book")
                            .font(.brandHeadline)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { TriageView() }
}
