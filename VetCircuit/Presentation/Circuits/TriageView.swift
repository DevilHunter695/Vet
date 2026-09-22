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
            switch outcome.recommendation {
            case .bookVisitUrgently: Haptics.warning()
            case .bookVisit: Haptics.tap()
            case .selfCare: Haptics.success()
            }
        } catch {
            Haptics.error()
            errorMessage = UserFacingError.message(for: error)
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
                    Text("Not a diagnosis — it points you to the right next step.")
                        .font(.brandBody)
                        .foregroundStyle(Theme.textSecondary)
                }
                .appearAnimation()

                Picker("Pet type", selection: $viewModel.species) {
                    ForEach(Pet.Species.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.species) { _, _ in Haptics.selection() }

                TextField("e.g. Not eating since yesterday, seems tired", text: $viewModel.symptoms, axis: .vertical)
                    .font(.brandBody)
                    .padding(Spacing.row)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                    .lineLimit(3...6)

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                PrimaryButton(title: "Check symptoms", isLoading: viewModel.isLoading) {
                    Task { await viewModel.assess() }
                }

                if let result = viewModel.result {
                    TriageResultCard(result: result, symptoms: viewModel.symptoms)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        // Same reason as the booking screen: a vertical-axis TextField has
        // no Return key to dismiss with, and there is no keyboard toolbar.
        .scrollDismissesKeyboard(.interactively)
        .floatingTabBarInset()
        .navigationTitle("Symptom check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // C11's escalation stays one tap away, but out of the centre.
            // A full-width red slab above the form made the screen shout
            // "emergency" at everyone, including the majority whose pet has
            // a mild problem - and shouting at every visitor is how a real
            // alarm gets tuned out.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    EmergencyView()
                } label: {
                    Label("Emergency", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                }
                .accessibilityLabel("This is an emergency")
            }
        }
    }
}

private struct TriageResultCard: View {
    let result: TriageResult
    /// Carried to the booking screen so the person doesn't get asked what's
    /// wrong twice — see `BookingDraft`.
    let symptoms: String

    @Environment(BookingDraft.self) private var bookingDraft

    private var accent: Color {
        switch result.recommendation {
        case .bookVisitUrgently: return Theme.danger
        case .bookVisit: return Theme.warning
        case .selfCare: return Theme.success
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
                    .foregroundStyle(Theme.textSecondary)

                if result.recommendation != .selfCare {
                    // This is the only action offered to a worried owner
                    // we've just told to book — it gets a real, full-width
                    // 44pt target, not a bare line of text.
                    NavigationLink {
                        CircuitsListView()
                            .onAppear { bookingDraft.setReason(symptoms) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.plus")
                                .scaledIcon(16, weight: .semibold)
                            Text("Browse circuits to book").font(.brandHeadline)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, Spacing.gutter)
                        .padding(.vertical, Spacing.snug)
                        .background {
                            RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous)
                                .fill(accent)
                                .allowsHitTesting(false)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.975))
                    .accessibilityLabel("Browse circuits to book a visit")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { TriageView() }
        .environment(BookingDraft())
}
