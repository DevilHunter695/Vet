import SwiftUI
import MapKit

/// C7: map view of cluster coverage — shows every served cluster as a
/// labeled circle so a customer (or someone deciding whether to move) can
/// see at a glance where circuits actually run, rather than reading a list
/// of area names.
@Observable
@MainActor
final class CoverageMapViewModel {
    var clusters: [ServedCluster] = []
    var errorMessage: String?
    var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946),
                            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35))
    )

    private let getServedClustersUseCase = DependencyContainer.shared.getServedClustersUseCase()

    func load() async {
        do {
            clusters = try await getServedClustersUseCase.execute()
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

struct CoverageMapView: View {
    @State private var viewModel = CoverageMapViewModel()

    var body: some View {
        Map(position: $viewModel.cameraPosition) {
            ForEach(viewModel.clusters) { cluster in
                let coordinate = CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)
                MapCircle(center: coordinate, radius: cluster.radiusKm * 1000)
                    .foregroundStyle(Theme.primary.opacity(0.15))
                    .stroke(Theme.primary, lineWidth: 1.5)
                Marker(cluster.area, coordinate: coordinate)
                    .tint(Theme.primary)
            }
        }
        .overlay(alignment: .top) {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage).padding()
            }
        }
        .navigationTitle("Coverage map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }
}

#Preview {
    NavigationStack { CoverageMapView() }
}
