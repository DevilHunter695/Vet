import SwiftUI

/// K6: shows the lab test reports attached to a visit's pet — pending
/// ("still processing") or ready (with a summary and a share-sheet, same
/// pattern as `PetDetailView`'s "Share health summary" for B7). Reports
/// themselves are uploaded ops-side; this view only reads/displays them.
struct LabTestReportsView: View {
    let petId: UUID
    let visitId: UUID?

    @State private var reports: [LabTestReport] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var shareURL: URL?
    @State private var showingShareSheet = false

    private let getLabTestReportsUseCase = DependencyContainer.shared.getLabTestReportsUseCase()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if reports.isEmpty {
                    Text("No lab tests have been ordered for this pet yet.")
                        .font(.brandBody)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reports) { report in
                        reportCard(report)
                    }
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Lab test reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showingShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
    }

    @ViewBuilder
    private func reportCard(_ report: LabTestReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(report.testName, systemImage: "cross.vial.fill")
                        .font(.brandHeadline)
                    Spacer()
                    statusBadge(report.status)
                }
                if let availableAt = report.availableAt {
                    Text("Available \(availableAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
                if let summary = report.resultSummary {
                    Text(summary).font(.brandBody)
                }
                switch report.status {
                case .pending:
                    Text("Still processing — you'll be able to view and share it here once it's ready.")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                case .ready:
                    if let fileURL = report.reportFileURL {
                        Button {
                            shareURL = fileURL
                            showingShareSheet = true
                        } label: {
                            Label("View / share report", systemImage: "square.and.arrow.up")
                        }
                        .font(.brandBody)
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: LabTestReport.Status) -> some View {
        let (text, color): (String, Color) = status == .ready ? ("Ready", Theme.success) : ("Pending", Theme.warning)
        Text(text)
            .font(.brandCaption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let visitId {
                reports = try await getLabTestReportsUseCase.forVisit(visitId)
            } else {
                reports = try await getLabTestReportsUseCase.forPet(petId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        LabTestReportsView(petId: MockData.user.pets[0].id, visitId: MockData.demoLabTestVisitId)
    }
}
