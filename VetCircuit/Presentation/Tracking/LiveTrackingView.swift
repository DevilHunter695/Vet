import SwiftUI
import MapKit
import UIKit

@Observable
@MainActor
final class LiveTrackingViewModel {
    let visitId: UUID
    var location: VetLocation?
    var cameraPosition: MapCameraPosition = .automatic
    private var subscriptionToken: AnyObject?

    // L4: SOS state — a share sheet URL once the incident is logged and the
    // link is ready, plus an error surfaced inline (never silently swallowed
    // for a safety action).
    var isSendingSOS = false
    var sosShareText: String?
    var sosErrorMessage: String?

    private let trackVetUseCase = DependencyContainer.shared.trackVetUseCase()
    private let sosUseCase = DependencyContainer.shared.sosUseCase()

    init(visitId: UUID) { self.visitId = visitId }

    /// L4: logs an `IncidentReport` (type `.sos`) and hands back share text
    /// carrying the `vetcircuit://visit/<id>` link for the system share
    /// sheet. Customer-only here (LiveTrackingView is the customer's
    /// tracking screen) — the vet side of an SOS would come from a separate
    /// vet-app entry point, out of scope for this app.
    func pressSOS(reporterId: UUID) async {
        isSendingSOS = true
        sosErrorMessage = nil
        defer { isSendingSOS = false }
        do {
            let result = try await sosUseCase.execute(visitId: visitId, reporterId: reporterId, reporterRole: .customer)
            Haptics.warning()
            sosShareText = ShareVisitLinkUseCase.shareMessage(visitId: result.report.visitId)
        } catch {
            Haptics.error()
            sosErrorMessage = error.localizedDescription
        }
    }

    func start() async {
        location = try? await trackVetUseCase.execute(visitId: visitId)
        updateCamera()
        startLiveActivity()
        subscriptionToken = trackVetUseCase.subscribe(visitId: visitId) { [weak self] update in
            Task { @MainActor in
                self?.location = update
                self?.updateCamera()
                await self?.updateLiveActivity()
            }
        }
    }

    /// I3: mirrors this screen's own state onto the Lock Screen/Dynamic
    /// Island via VetEnRouteActivityManager (VetEnRouteActivity.swift).
    private func startLiveActivity() {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            VetEnRouteActivityManager.start(visitId: visitId, vetName: "Your vet", etaMinutes: location?.etaMinutes, status: .enRoute)
        }
        #endif
    }

    private func updateLiveActivity() async {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            VetEnRouteActivityManager.update(etaMinutes: location?.etaMinutes, status: .enRoute)
        }
        #endif
    }

    func stop() {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            VetEnRouteActivityManager.end()
        }
        #endif
    }

    private func updateCamera() {
        guard let location else { return }
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        cameraPosition = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
    }
}

/// V2 live tracking: shown only while a visit is "en route" — a simple status
/// string covers the rest of the flow, this map is additive reassurance.
struct LiveTrackingView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel: LiveTrackingViewModel
    @State private var showingSOSConfirmation = false
    @State private var shareItems: [String]?

    init(visitId: UUID) { _viewModel = State(initialValue: LiveTrackingViewModel(visitId: visitId)) }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $viewModel.cameraPosition) {
                if let location = viewModel.location {
                    Marker("Vet", coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                        .tint(Theme.inProgress)
                }
            }
            .frame(height: 320)

            Card {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.inProgress.opacity(0.15))
                        Image(systemName: "figure.walk.motion").foregroundStyle(Theme.inProgress)
                    }
                    .frame(width: 40, height: 40)

                    if let eta = viewModel.location?.etaMinutes {
                        Text("Arriving in about \(eta) min").font(.brandHeadline)
                    } else {
                        Text("Waiting for location…").font(.brandBody).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .animation(Theme.springQuick, value: viewModel.location?.etaMinutes)
            }
            .padding()
            .appearAnimation()

            // L4: real visual weight — a full-width red button, not a
            // subtle icon — but a confirmation step so it can't fire from an
            // accidental tap while the phone is in a pocket.
            Button(role: .destructive) {
                Haptics.warning()
                showingSOSConfirmation = true
            } label: {
                Label("SOS — I need help", systemImage: "exclamationmark.triangle.fill")
                    .font(.brandHeadline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .disabled(viewModel.isSendingSOS)

            if let sosErrorMessage = viewModel.sosErrorMessage {
                ErrorBanner(message: sosErrorMessage)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .navigationTitle("Vet en route")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .confirmationDialog(
            "Send an SOS?",
            isPresented: $showingSOSConfirmation,
            titleVisibility: .visible
        ) {
            Button("Yes, send SOS", role: .destructive) {
                Task {
                    if let user = session.currentUser { await viewModel.pressSOS(reporterId: user.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This logs an incident and lets you share your live visit status with a trusted contact.")
        }
        .onChange(of: viewModel.sosShareText) { _, text in
            guard let text else { return }
            shareItems = [text]
        }
        .sheet(item: Binding(
            get: { shareItems.map { ShareItemsBox($0) } },
            set: { shareItems = $0?.items }
        )) { box in
            SOSShareSheet(items: box.items)
        }
    }
}

/// Bridges `[String]` (not `Identifiable`) into `.sheet(item:)`.
private struct ShareItemsBox: Identifiable {
    let id = UUID()
    let items: [String]
    init(_ items: [String]) { self.items = items }
}

private struct SOSShareSheet: UIViewControllerRepresentable {
    let items: [String]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack { LiveTrackingView(visitId: UUID()) }
        .environment(SessionStore())
}
