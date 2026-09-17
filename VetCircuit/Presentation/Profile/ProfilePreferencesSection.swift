import SwiftUI

/// Care-type, appearance and biometric-lock toggles plus the notification
/// links. Extracted from `ProfileView` per the "one type per file" rule; the
/// three settings stay as bindings so this view has no state of its own and
/// changes flow straight back into the `@AppStorage`-backed source of truth.
struct ProfilePreferencesSection: View {
    @Binding var selectedVertical: Vertical
    @Binding var appearance: AppearanceOption
    @Binding var biometricLockEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Preferences", systemImage: "slider.horizontal.3")

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Care type").brandEyebrow()
                    Picker("Care type", selection: $selectedVertical) {
                        ForEach(Vertical.allCases) { vertical in
                            Text(vertical.displayName).tag(vertical)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedVertical) { _, _ in Haptics.selection() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance").brandEyebrow()
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { _, _ in Haptics.selection() }
                    Text("The blue-green aurora is tuned for both — dark leans into it, light keeps it as a wash.")
                        .font(.brandCaption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                GlassSeam()

                Toggle(isOn: $biometricLockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require Face ID to open").font(.brandCallout)
                        Text("Locks the app whenever it goes to the background.")
                            .font(.brandCaption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.primary)
                .onChange(of: biometricLockEnabled) { _, _ in Haptics.selection() }
            }
            .padding(16)
            .glassCard()

            ProfileGroup(title: "Notifications", systemImage: "bell.badge") {
                ProfileLinkRow(title: "Notification preferences", subtitle: "Choose what reaches you", systemImage: "bell") { NotificationPreferencesView() }
                ProfileLinkRow(title: "Notification centre", subtitle: "Everything we've sent you", systemImage: "tray") { NotificationCenterView() }
            }
        }
    }
}
