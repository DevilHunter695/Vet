import SwiftUI
import MapKit

@Observable
@MainActor
final class LiveTrackingViewModel {
    let visitId: UUID
    var location: VetLocation?
    var cameraPosition: MapCameraPosition = .automatic
    private var subscriptionToken: AnyObject?

    private let trackVetUseCase = DependencyContainer.shared.trackVetUseCase()

    init(visitId: UUID) { self.visitId = visitId }

    func start() async {
        location = try? await trackVetUseCase.execute(visitId: visitId)
        updateCamera()
        subscriptionToken = trackVetUseCase.subscribe(visitId: visitId) { [weak self] update in
            Task { @MainActor in
                self?.location = update
                self?.updateCamera()
            }
        }
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
    @State private var viewModel: LiveTrackingViewModel

    init(visitId: UUID) { _viewModel = State(initialValue: LiveTrackingViewModel(visitId: visitId)) }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $viewModel.cameraPosition) {
                if let location = viewModel.location {
                    Marker("Vet", coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                        .tint(.purple)
                }
            }
            .frame(height: 320)

            Card {
                HStack {
                    Image(systemName: "figure.walk.motion").foregroundStyle(.purple)
                    if let eta = viewModel.location?.etaMinutes {
                        Text("Arriving in about \(eta) min").fontWeight(.semibold)
                    } else {
                        Text("Waiting for location…").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding()

            Spacer()
        }
        .navigationTitle("Vet en route")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
    }
}

#Preview {
    NavigationStack { LiveTrackingView(visitId: UUID()) }
}
