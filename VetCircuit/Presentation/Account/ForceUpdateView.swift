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
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if case .forceUpgrade = mode {
                    Button {
                        Haptics.tap()
                        if let url = URL(string: "itms-apps://apps.apple.com/app/id0000000000") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Update now")
                            .font(.brandHeadline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
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
    ForceUpdateView(mode: .maintenance(message: "We're upgrading our booking system. Back by 6pm."))
}

#Preview("Force upgrade") {
    ForceUpdateView(mode: .forceUpgrade(minVersion: "2.0"))
}
