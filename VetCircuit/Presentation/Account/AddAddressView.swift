import SwiftUI
import MapKit

struct AddAddressView: View {
    let ownerId: UUID
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var line1 = ""
    @State private var landmark = ""
    @State private var accessNotes = ""
    @State private var coordinate = CLLocationCoordinate2D(latitude: 12.9352, longitude: 77.6146)
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: .init(latitude: 12.9352, longitude: 77.6146), latitudinalMeters: 1500, longitudinalMeters: 1500)
    )
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let manageAddressesUseCase = DependencyContainer.shared.manageAddressesUseCase()

    var body: some View {
        NavigationStack {
            Form {
                Section("Pin the location") {
                    ZStack {
                        Map(position: $cameraPosition)
                            .frame(height: 220)
                        Image(systemName: "mappin")
                            .font(.title)
                            .foregroundStyle(Theme.danger)
                            .offset(y: -14)
                            // Decorative only — without this the glyph eats
                            // pan gestures that start on it and the pin (and
                            // the saved coordinate) never moves.
                            .allowsHitTesting(false)
                    }
                    .listRowInsets(EdgeInsets())
                    .onMapCameraChange { context in
                        coordinate = context.region.center
                    }
                    Text("Move the map so the pin sits on your gate.")
                        .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                }

                Section("Details") {
                    TextField("Label (Home, Office…)", text: $label)
                    TextField("Address line", text: $line1)
                    TextField("Landmark (optional)", text: $landmark)
                    TextField("Access notes (gate code, floor…)", text: $accessNotes, axis: .vertical)
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            // The aurora is the app's ground everywhere else; a List that keeps
            // its own opaque system background would read as a different app.
            .scrollContentBackground(.hidden)
            .auroraScreenBackground()
            .navigationTitle("Add address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || line1.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let address = Address(
            id: UUID(), ownerId: ownerId, label: label, line1: line1,
            line2: nil, landmark: landmark.isEmpty ? nil : landmark,
            accessNotes: accessNotes.isEmpty ? nil : accessNotes,
            latitude: coordinate.latitude, longitude: coordinate.longitude, clusterArea: nil
        )
        do {
            _ = try await manageAddressesUseCase.add(address)
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            Haptics.error()
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

#Preview {
    AddAddressView(ownerId: UUID()) {}
}
