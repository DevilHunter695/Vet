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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: LiveTrackingViewModel
    @State private var showingSOSConfirmation = false
    /// The SOS share sheet's payload, held directly rather than rebuilt in a
    /// binding. See `ShareItemsBox` for why that distinction matters here.
    @State private var shareBox: ShareItemsBox?

    init(visitId: UUID) { _viewModel = State(initialValue: LiveTrackingViewModel(visitId: visitId)) }

    /// How fresh the ETA is. A stale "arriving in 5 min" with no indication of
    /// when it was last heard is worse than no number at all.
    private var lastUpdatedText: String {
        guard let updatedAt = viewModel.location?.updatedAt else { return "just now" }
        let seconds = Int(Date().timeIntervalSince(updatedAt))
        if seconds < 60 { return "just now" }
        return "\(seconds / 60) min ago"
    }

    var body: some View {
        // The map is the screen, not a 320pt band with dead space under it.
        // Everything else floats over it, which is also how every other
        // arrival-tracking product people already use behaves.
        Map(position: $viewModel.cameraPosition) {
            if let location = viewModel.location {
                Marker("Vet", coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                    .tint(Theme.inProgress)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if let sosErrorMessage = viewModel.sosErrorMessage {
                    ErrorBanner(message: sosErrorMessage)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Theme.inProgress.opacity(0.18))
                            Image(systemName: "figure.walk.motion")
                                .foregroundStyle(Theme.inProgress)
                                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, value: viewModel.location != nil)
                        }
                        .frame(width: 44, height: 44)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            if let eta = viewModel.location?.etaMinutes {
                                Text("Arriving in about \(eta) min")
                                    .font(.brandHeadline)
                                    .contentTransition(.numericText())
                                Text("Updated \(lastUpdatedText)")
                                    .font(.brandCaption)
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Text("Waiting for your vet's location…")
                                    .font(.brandCallout)
                                Text("The map updates as soon as they start moving.")
                                    .font(.brandCaption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .animation(reduceMotion ? nil : Theme.springQuick, value: viewModel.location?.etaMinutes)

                    CalloutNote(
                        text: "Have your pet somewhere calm and easy to reach, and keep your phone handy — the vet will ask for your start-of-visit code on arrival.",
                        systemImage: "lightbulb.fill"
                    )

                    // L4: real visual weight — a full-width red button, not a
                    // subtle icon — but a confirmation step so it can't fire
                    // from an accidental tap while the phone is in a pocket.
                    Button {
                        Haptics.warning()
                        showingSOSConfirmation = true
                    } label: {
                        Label("SOS — I need help", systemImage: "exclamationmark.triangle.fill")
                            .font(.brandHeadline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 26)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(Theme.danger, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.975))
                    .disabled(viewModel.isSendingSOS)
                    .opacity(viewModel.isSendingSOS ? 0.6 : 1)
                }
                .padding(16)
                .glassCard()
            }
            .padding(16)
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
            shareBox = ShareItemsBox([text])
        }
        .sheet(item: $shareBox) { box in
            SOSShareSheet(items: box.items)
        }
    }
}

/// Bridges `[String]` (not `Identifiable`) into `.sheet(item:)`.
///
/// This used to be built inside a `Binding(get:set:)` in the view body, which
/// meant a fresh `UUID()` on every body evaluation. On this screen in
/// particular that is not theoretical: live tracking publishes location
/// updates continuously, so while the SOS share sheet was open the item's
/// identity changed under it several times a second, and SwiftUI treats a new
/// identity as a different sheet. It is now held in `@State` and set from
/// `onChange`, so the identity changes exactly when the payload does.
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
