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
            result = try await runTriageUseCase.execute(species: species, symptoms: symptoms)
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
                Text("Tell us what's going on")
                    .font(.title3.bold())
                Text("This isn't a diagnosis — it helps us point you to the right next step.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Pet type", selection: $viewModel.species) {
                    ForEach(Pet.Species.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("e.g. Not eating since yesterday, seems tired", text: $viewModel.symptoms, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                PrimaryButton(title: "Check symptoms", isLoading: viewModel.isLoading) {
                    Task { await viewModel.assess() }
                }

                if let result = viewModel.result {
                    TriageResultCard(result: result)
                }
            }
            .padding()
        }
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

    private var title: String {
        switch result.recommendation {
        case .bookVisitUrgently: return "Book a visit now"
        case .bookVisit: return "Consider booking a visit"
        case .selfCare: return "Likely okay to monitor at home"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "stethoscope")
                    .font(.headline)
                    .foregroundStyle(accent)
                Text(result.message)
                    .foregroundStyle(.secondary)

                if result.recommendation != .selfCare {
                    NavigationLink("Browse circuits to book") {
                        CircuitsListView()
                    }
                    .font(.subheadline.weight(.semibold))
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
