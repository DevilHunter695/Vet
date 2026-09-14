import SwiftUI
import Charts
import PhotosUI

/// B2: the pet health-record screen the app lacked entirely — everything
/// before this lived as a name+species row in `ProfileView`. B3/B4/K2 (weight
/// chart, vaccinations, prescriptions) and B8 (archive) all hang off here
/// rather than getting their own top-level screens, since they're all "one
/// pet's record", not separate flows.
@Observable
@MainActor
final class PetDetailViewModel {
    var pet: Pet
    var weightHistory: [PetWeightEntry] = []
    var vaccinations: [Vaccination] = []
    var prescriptions: [Prescription] = []
    var errorMessage: String?
    var isSaving = false

    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let managePetWeightsUseCase = DependencyContainer.shared.managePetWeightsUseCase()
    private let manageVaccinationsUseCase = DependencyContainer.shared.manageVaccinationsUseCase()
    private let managePrescriptionsUseCase = DependencyContainer.shared.managePrescriptionsUseCase()

    init(pet: Pet) { self.pet = pet }

    func load() async {
        async let weights = managePetWeightsUseCase.history(petId: pet.id)
        async let shots = manageVaccinationsUseCase.history(petId: pet.id)
        async let scripts = managePrescriptionsUseCase.history(petId: pet.id)
        do {
            weightHistory = try await weights
            vaccinations = try await shots
            prescriptions = try await scripts
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            pet = try await managePetsUseCase.update(pet)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addWeight(_ weightKg: Double, temperatureCelsius: Double? = nil, heartRateBpm: Int? = nil) async {
        do {
            let entry = try await managePetWeightsUseCase.addEntry(petId: pet.id, weightKg: weightKg,
                                                                     temperatureCelsius: temperatureCelsius, heartRateBpm: heartRateBpm)
            withAnimation(Theme.springSoft) { weightHistory.append(entry) }
            pet.weightKg = weightKg
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// B2: uploads a newly-picked photo and swaps it into `pet.photoURL`.
    func updatePhoto(data: Data) async {
        do {
            pet = try await managePetsUseCase.updatePhoto(petId: pet.id, data: data)
            Haptics.success()
        } catch {
            errorMessage = "Couldn't upload that photo."
        }
    }

    /// B8: sensitive-copy soft delete — the pet's history stays put, it just
    /// stops surfacing in bookings and vaccination nagging (`ManagePetsUseCase.list`).
    func archive(reason: Pet.ArchiveReason) async {
        do {
            pet = try await managePetsUseCase.archive(pet, reason: reason)
            Haptics.confirm()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unarchive() async {
        do {
            pet = try await managePetsUseCase.unarchive(pet)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var nextActionableVaccination: Vaccination? {
        vaccinations.first { $0.dueStatus() != .upToDate }
    }

    // MARK: - B7: shareable PDF health summary

    private let generateHealthSummaryUseCase = DependencyContainer.shared.generatePetHealthSummaryUseCase()

    /// Renders the PDF to a temp file (rather than sharing raw `Data`) so the
    /// share sheet — Mail, Files, AirDrop — sees a real `.pdf` with a sensible
    /// name instead of an untyped data blob.
    func generateHealthSummaryFile() -> URL? {
        let data = generateHealthSummaryUseCase.execute(pet: pet, weightHistory: weightHistory, vaccinations: vaccinations)
        guard !data.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(pet.name)-health-summary-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "Couldn't prepare the PDF for sharing."
            return nil
        }
    }
}

struct PetDetailView: View {
    @State private var viewModel: PetDetailViewModel
    @State private var showingAddWeight = false
    @State private var newWeightText = ""
    @State private var newTemperatureText = ""
    @State private var newHeartRateText = ""
    @State private var showingArchiveConfirm = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingArchiveReason: Pet.ArchiveReason = .other
    @State private var bookVaccinationService: Service?
    @State private var shareFileURL: URL?
    @State private var showingShareSheet = false

    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()

    init(pet: Pet) {
        _viewModel = State(initialValue: PetDetailViewModel(pet: pet))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.pet.isArchived, let reason = viewModel.pet.archiveReason {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(reason.displayName, systemImage: "heart.text.square")
                                .font(.brandHeadline).foregroundStyle(.secondary)
                            Text("This pet's record is kept, but it won't show up when booking a visit or for vaccination reminders.")
                                .font(.brandCaption).foregroundStyle(.secondary)
                            Button("Bring this pet back") { Task { await viewModel.unarchive() } }
                                .font(.brandCaption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation()
                }

                petInfoCard.appearAnimation(delay: 0.05)
                weightCard.appearAnimation(delay: 0.1)
                vaccinationCard.appearAnimation(delay: 0.15)
                if !viewModel.prescriptions.isEmpty {
                    prescriptionCard.appearAnimation(delay: 0.2)
                }
                medicationRemindersLink.appearAnimation(delay: 0.22)

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                documentVaultLink.appearAnimation(delay: 0.22)
                labTestReportsLink.appearAnimation(delay: 0.22)

                Button {
                    if let url = viewModel.generateHealthSummaryFile() {
                        shareFileURL = url
                        showingShareSheet = true
                    }
                } label: {
                    Label("Share health summary", systemImage: "square.and.arrow.up")
                }
                .font(.brandBody)
                .buttonStyle(.bordered)
                .padding(.top, 4)

                if !viewModel.pet.isArchived {
                    Button(role: .destructive) {
                        showingArchiveConfirm = true
                    } label: {
                        Label("This pet is no longer with you", systemImage: "heart.slash")
                    }
                    .font(.brandBody)
                    .padding(.top, 8)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(viewModel.pet.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .sheet(isPresented: $showingAddWeight) { addWeightSheet }
        .sheet(item: $bookVaccinationService) { service in
            NavigationStack {
                ServiceDetailView(service: service, pet: viewModel.pet, preselectedVariantId: service.variants.first?.id)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let shareFileURL {
                ShareSheet(activityItems: [shareFileURL])
            }
        }
        // B8: a confirmation dialog, not a plain destructive button tap — and
        // the copy names what's actually happening ("no longer with you"),
        // never "delete", per plan §B8.
        .confirmationDialog(
            "This won't remove \(viewModel.pet.name)'s past visits or records.",
            isPresented: $showingArchiveConfirm,
            titleVisibility: .visible
        ) {
            ForEach(Pet.ArchiveReason.allCases, id: \.self) { reason in
                Button(reason.displayName) {
                    Task { await viewModel.archive(reason: reason) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Pet info (B2)

    private var petInfoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pet details", systemImage: "pawprint.fill")
                    .font(.brandHeadline).foregroundStyle(Theme.primary)

                // B2: photo upload — PhotosPicker → JPEG data → ManagePetsUseCase.updatePhoto.
                HStack {
                    if let photoURL = viewModel.pet.photoURL {
                        AsyncImage(url: photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color(.tertiarySystemFill))
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Circle().fill(Color(.tertiarySystemFill))
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "pawprint.fill").foregroundStyle(.secondary))
                    }
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Text(viewModel.pet.photoURL == nil ? "Add photo" : "Change photo")
                            .font(.brandCaption)
                    }
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        guard let newItem, let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                        await viewModel.updatePhoto(data: data)
                    }
                }

                LabeledContent("Species", value: viewModel.pet.species.rawValue.capitalized)
                if let breed = viewModel.pet.breed, !breed.isEmpty {
                    LabeledContent("Breed", value: breed)
                }

                Picker("Sex", selection: Binding(
                    get: { viewModel.pet.sex ?? .unknown },
                    set: { viewModel.pet.sex = $0 }
                )) {
                    ForEach(Pet.Sex.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }

                Toggle("Neutered / spayed", isOn: Binding(
                    get: { viewModel.pet.isNeutered ?? false },
                    set: { viewModel.pet.isNeutered = $0 }
                ))

                TextField("Microchip number", text: Binding(
                    get: { viewModel.pet.microchipNumber ?? "" },
                    set: { viewModel.pet.microchipNumber = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Allergies", text: Binding(
                    get: { viewModel.pet.allergies ?? "" },
                    set: { viewModel.pet.allergies = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Chronic conditions", text: Binding(
                    get: { viewModel.pet.chronicConditions ?? "" },
                    set: { viewModel.pet.chronicConditions = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                Button(viewModel.isSaving ? "Saving…" : "Save changes") {
                    Task { await viewModel.save() }
                }
                .disabled(viewModel.isSaving)
                .font(.brandBody)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Weight & vitals (B3)

    private var weightCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Weight", systemImage: "scalemass.fill")
                        .font(.brandHeadline).foregroundStyle(Theme.primary)
                    Spacer()
                    Button("Add weight") { showingAddWeight = true }
                        .font(.brandCaption)
                }

                if viewModel.weightHistory.isEmpty {
                    Text("No weight readings yet.").font(.brandCaption).foregroundStyle(.secondary)
                } else {
                    Chart(viewModel.weightHistory) { entry in
                        LineMark(x: .value("Date", entry.recordedAt), y: .value("kg", entry.weightKg))
                        PointMark(x: .value("Date", entry.recordedAt), y: .value("kg", entry.weightKg))
                    }
                    .foregroundStyle(Theme.primary)
                    .frame(height: 140)

                    if let latest = viewModel.weightHistory.last {
                        Text("Latest: \(latest.weightKg, specifier: "%.1f") kg on \(latest.recordedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.brandCaption).foregroundStyle(.secondary)
                        // B3: vitals beyond weight — shown only when present.
                        if latest.temperatureCelsius != nil || latest.heartRateBpm != nil {
                            HStack(spacing: 12) {
                                if let temp = latest.temperatureCelsius {
                                    Label("\(temp, specifier: "%.1f")°C", systemImage: "thermometer.medium")
                                }
                                if let hr = latest.heartRateBpm {
                                    Label("\(hr) bpm", systemImage: "heart.fill")
                                }
                            }
                            .font(.brandCaption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var addWeightSheet: some View {
        NavigationStack {
            Form {
                TextField("Weight in kg", text: $newWeightText)
                    .keyboardType(.decimalPad)
                // B3: vitals beyond weight — optional, so a plain owner
                // logging weight at home never has to fill these in.
                TextField("Temperature in °C (optional)", text: $newTemperatureText)
                    .keyboardType(.decimalPad)
                TextField("Heart rate in bpm (optional)", text: $newHeartRateText)
                    .keyboardType(.numberPad)
            }
            .navigationTitle("Add weight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let value = Double(newWeightText) {
                            let temperature = Double(newTemperatureText)
                            let heartRate = Int(newHeartRateText)
                            Task {
                                await viewModel.addWeight(value, temperatureCelsius: temperature, heartRateBpm: heartRate)
                                newWeightText = ""
                                newTemperatureText = ""
                                newHeartRateText = ""
                                showingAddWeight = false
                            }
                        }
                    }
                    .disabled(Double(newWeightText) == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddWeight = false }
                }
            }
        }
    }

    // MARK: - Vaccinations (B4, P0)

    private var vaccinationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Vaccinations", systemImage: "syringe.fill")
                    .font(.brandHeadline).foregroundStyle(Theme.primary)

                if viewModel.vaccinations.isEmpty {
                    Text("No vaccination records yet.").font(.brandCaption).foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.vaccinations) { vaccination in
                        VaccinationRow(vaccination: vaccination)
                    }
                }

                if let due = viewModel.nextActionableVaccination, !viewModel.pet.isArchived {
                    Button {
                        Task { await bookVaccination(for: due) }
                    } label: {
                        Label("Book vaccination visit", systemImage: "calendar.badge.plus")
                    }
                    .font(.brandBody)
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// K4-adjacent 1-tap action: jumps straight to the vaccination service's
    /// booking screen for this pet rather than making the owner navigate the
    /// catalog themselves.
    private func bookVaccination(for due: Vaccination) async {
        guard let services = try? await getCatalogUseCase.execute(vertical: .vet, forSpecies: viewModel.pet.species),
              let service = services.first(where: { $0.category == .vaccination }) else { return }
        bookVaccinationService = service
    }

    // MARK: - Document vault (B6)

    private var documentVaultLink: some View {
        NavigationLink {
            DocumentVaultView(pet: viewModel.pet)
        } label: {
            Card {
                HStack {
                    Label("Document vault", systemImage: "doc.text.fill")
                        .font(.brandHeadline).foregroundStyle(Theme.primary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lab test reports (K6)

    private var labTestReportsLink: some View {
        NavigationLink {
            LabTestReportsView(petId: viewModel.pet.id, visitId: nil)
        } label: {
            Card {
                HStack {
                    Label("Lab test reports", systemImage: "cross.vial.fill")
                        .font(.brandHeadline).foregroundStyle(Theme.primary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Prescriptions (K2)

    private var prescriptionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Prescriptions", systemImage: "pills.fill")
                    .font(.brandHeadline).foregroundStyle(Theme.primary)
                ForEach(viewModel.prescriptions) { prescription in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(prescription.medicationName) — \(prescription.dosage)").font(.brandBody)
                        if let instructions = prescription.instructions {
                            Text(instructions).font(.brandCaption).foregroundStyle(.secondary)
                        }
                        Text(prescription.issuedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.brandCaption).foregroundStyle(.tertiary)
                    }
                    if prescription.id != viewModel.prescriptions.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Medication reminders (K3)

    private var medicationRemindersLink: some View {
        NavigationLink {
            MedicationRemindersView(pet: viewModel.pet)
        } label: {
            Card {
                Label("Medication reminders", systemImage: "bell.badge.fill")
                    .font(.brandHeadline).foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct VaccinationRow: View {
    let vaccination: Vaccination

    private var color: Color {
        switch vaccination.dueStatus() {
        case .upToDate: return .secondary
        case .dueSoon: return .orange
        case .overdue: return .red
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(vaccination.vaccineName).font(.brandBody)
                if let given = vaccination.givenAt {
                    Text("Given \(given.formatted(date: .abbreviated, time: .omitted))")
                        .font(.brandCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Next due").font(.brandCaption).foregroundStyle(.secondary)
                Text(vaccination.nextDueAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.brandCaption.weight(.semibold))
                    .foregroundStyle(color)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { PetDetailView(pet: MockData.user.pets.first ?? Pet(id: UUID(), ownerId: UUID(), name: "Bruno", species: .dog, breed: "Labrador", dateOfBirth: nil)) }
}
