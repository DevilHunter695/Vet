import SwiftUI
import UIKit

/// O7/O8: one full-screen blocking view for both server-driven gates — plan
/// calls the force-upgrade check "your only true rollback lever for a shipped
/// binary", so this has to be unmissable and unavoidable, not a dismissible
/// banner. `RootView` shows this instead of sign-in/tabs whenever the gate
/// trips; there is deliberately no way to swipe or tap past it.
struct ForceUpdateView: View {
    enum Mode: Equatable {
        case maintenance(message: String?)
        case forceUpgrade(minVersion: String)
    }

    let mode: Mode

    /// Maintenance ends without the app being relaunched, so the gate has to
    /// offer a way back in. Without this the screen is a dead end: the check
    /// only ran once, in `RootView`'s `.task`, and nothing re-ran it.
    var onRetry: (() async -> Void)?

    @State private var isRetrying = false

    var body: some View {
        ZStack {
            Theme.heroGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                PawMascot(size: 88, animated: false)

                Text(title)
                    .font(.brandTitle)
                    .brandDisplayText()
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.brandBody)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.major)

                switch mode {
                case .forceUpgrade:
                    Button {
                        Haptics.tap()
                        UIApplication.shared.open(AppConfig.appStoreURL)
                    } label: {
                        Text("Update now")
                            .font(.brandHeadline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .padding(.horizontal, Spacing.major)
                    .padding(.top, 8)

                case .maintenance:
                    if let onRetry {
                        Button {
                            Haptics.tap()
                            isRetrying = true
                            Task {
                                await onRetry()
                                isRetrying = false
                            }
                        } label: {
                            Group {
                                if isRetrying {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Try again")
                                }
                            }
                            .font(.brandHeadline)
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary)
                        .disabled(isRetrying)
                        .padding(.horizontal, Spacing.major)
                        .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
    }

    private var title: String {
        switch mode {
        case .maintenance: return "Down for maintenance"
        case .forceUpgrade: return "Update required"
        }
    }

    private var message: String {
        switch mode {
        case .maintenance(let message):
            return message ?? "VetCircuit is briefly offline for scheduled maintenance. Please check back shortly."
        case .forceUpgrade(let minVersion):
            return "This version of VetCircuit is no longer supported. Update to version \(minVersion) or later to continue."
        }
    }
}

#Preview("Maintenance") {
    ForceUpdateView(mode: .maintenance(message: "We're upgrading our booking system. Back by 6pm.")) {}
}

#Preview("Force upgrade") {
    ForceUpdateView(mode: .forceUpgrade(minVersion: "2.0"))
}
