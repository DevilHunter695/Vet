import SwiftUI
import LocalAuthentication

// A10: local device preference only — this is not account/session security,
// it's an extra local gate on top of an already-authenticated session, so a
// plain UserDefaults flag (no server round-trip, no repository) is the right
// weight. LocalAuthentication is a system framework, so this lives in the
// App layer, never Domain (see Domain layer's "pure Swift" rule).
enum BiometricLockSetting {
    private static let key = "vc.biometric_lock_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Whether the device can even evaluate biometrics right now (enrolled
    /// Face ID/Touch ID, not disabled by MDM, etc.) — checked fresh each time
    /// rather than cached, since enrollment can change while the app is
    /// backgrounded (plan note: "don't lock the user out").
    static func isAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
}

/// Shown at launch/foreground-return when the setting is on. Sits above
/// `MainTabView` exactly like `ForceUpdateView` in `RootView` — see
/// VetCircuitApp.swift's gating `Group`.
@MainActor
@Observable
final class BiometricLockGateModel {
    var isUnlocked = false
    var unavailableNote: String?

    /// Evaluated once per cold launch / foreground return, not per view
    /// redraw — `RootView` drives this from `.task`/scenePhase.
    func attemptUnlock() {
        guard BiometricLockSetting.isEnabled else {
            isUnlocked = true
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Graceful fallback: never strand the user behind a lock the
            // device can't satisfy (no enrolled Face ID, simulator, etc.).
            unavailableNote = "Face ID isn't set up on this device — app lock is off until it is."
            isUnlocked = true
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock VetCircuit") { [weak self] success, _ in
            Task { @MainActor in
                self?.isUnlocked = success
            }
        }
    }

    func lock() {
        guard BiometricLockSetting.isEnabled else { return }
        isUnlocked = false
    }
}

struct BiometricLockGateView: View {
    let model: BiometricLockGateModel

    var body: some View {
        ZStack {
            Theme.heroGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "faceid")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                Text("VetCircuit is locked").font(.brandHeadline).foregroundStyle(.white)
                if let note = model.unavailableNote {
                    Text(note).font(.brandCaption).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                Button {
                    Haptics.tap()
                    model.attemptUnlock()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.brandHeadline)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(.white, in: Capsule())
                        .foregroundStyle(Theme.primary)
                }
            }
        }
        .task { model.attemptUnlock() }
    }
}
