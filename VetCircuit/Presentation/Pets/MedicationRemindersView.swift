import SwiftUI

/// K3: list + add/edit form for a pet's medication reminders, reachable from
/// `PetDetailView` next to Prescriptions since the two are closely related
/// (a prescription is often exactly what a reminder gets set up for).
@Observable
@MainActor
final class MedicationRemindersViewModel {
    let pet: Pet
    var reminders: [MedicationReminder] = []
    var errorMessage: String?
    var isSaving = false

    private let manageMedicationRemindersUseCase = DependencyContainer.shared.manageMedicationRemindersUseCase()

    init(pet: Pet) { self.pet = pet }

    func load() async {
        do {
            reminders = try await manageMedicationRemindersUseCase.list(petId: pet.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(medicationName: String, dosage: String, times: [TimeOfDay], startDate: Date, endDate: Date?) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let reminder = try await manageMedicationRemindersUseCase.add(
                petId: pet.id, medicationName: medicationName, dosage: dosage, times: times, startDate: startDate, endDate: endDate
            )
            withAnimation(Theme.springSoft) { reminders.append(reminder) }
            PushNotificationManager.shared.scheduleMedicationReminders(reminder, petName: pet.name)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setActive(_ reminder: MedicationReminder, isActive: Bool) async {
        do {
            let updated = try await manageMedicationRemindersUseCase.setActive(reminder, isActive: isActive)
            if let index = reminders.firstIndex(where: { $0.id == updated.id }) {
                reminders[index] = updated
            }
            if isActive {
                PushNotificationManager.shared.scheduleMedicationReminders(updated, petName: pet.name)
            } else {
                PushNotificationManager.shared.cancelMedicationReminders(reminderId: updated.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ reminder: MedicationReminder) async {
        do {
            try await manageMedicationRemindersUseCase.remove(id: reminder.id)
            reminders.removeAll { $0.id == reminder.id }
            PushNotificationManager.shared.cancelMedicationReminders(reminderId: reminder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MedicationRemindersView: View {
    @State private var viewModel: MedicationRemindersViewModel
    @State private var showingAddForm = false

    init(pet: Pet) {
        _viewModel = State(initialValue: MedicationRemindersViewModel(pet: pet))
    }

    var body: some View {
        List {
            if viewModel.reminders.isEmpty {
                EmptyStateView(
                    systemImage: "bell.badge",
                    title: "No reminders yet",
                    message: "Set one and we'll nudge you at each dose time — the hard part of a course of medication is remembering the fourth day.",
                    actionTitle: "Add a reminder"
                ) {
                    showingAddForm = true
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.reminders) { reminder in
                    MedicationReminderRow(reminder: reminder) { isActive in
                        Task { await viewModel.setActive(reminder, isActive: isActive) }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { Task { await viewModel.remove(viewModel.reminders[index]) } }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Medication reminders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddForm = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showingAddForm) {
            AddMedicationReminderForm { medicationName, dosage, times, startDate, endDate in
                Task {
                    await viewModel.add(medicationName: medicationName, dosage: dosage, times: times, startDate: startDate, endDate: endDate)
                    showingAddForm = false
                }
            }
        }
    }
}

private struct MedicationReminderRow: View {
    let reminder: MedicationReminder
    let onToggleActive: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(reminder.medicationName).font(.brandBody.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { reminder.isActive }, set: onToggleActive))
                    .labelsHidden()
            }
            if !reminder.dosage.isEmpty {
                Text(reminder.dosage).font(.brandCaption).foregroundStyle(Theme.textSecondary)
            }
            Text(reminder.times.map(\.displayText).joined(separator: ", "))
                .font(.brandCaption).foregroundStyle(Theme.textSecondary)
            if let endDate = reminder.endDate {
                Text("Through \(endDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.brandCaption).foregroundStyle(Theme.textTertiary)
            } else {
                Text("Ongoing").font(.brandCaption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AddMedicationReminderForm: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String, [TimeOfDay], Date, Date?) -> Void

    @State private var medicationName = ""
    @State private var dosage = ""
    @State private var timeOfDay = Date()
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication") {
                    TextField("Name", text: $medicationName)
                    TextField("Dosage (e.g. 1 tablet)", text: $dosage)
                }
                Section("Schedule") {
                    DatePicker("Time of day", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    Toggle("Has an end date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("End date", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("New reminder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let components = Calendar.current.dateComponents([.hour, .minute], from: timeOfDay)
                        let time = TimeOfDay(hour: components.hour ?? 8, minute: components.minute ?? 0)
                        onSave(medicationName, dosage, [time], startDate, hasEndDate ? endDate : nil)
                    }
                    .disabled(medicationName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { MedicationRemindersView(pet: MockData.user.pets.first ?? Pet(id: UUID(), ownerId: UUID(), name: "Bruno", species: .dog, breed: "Labrador", dateOfBirth: nil)) }
}
