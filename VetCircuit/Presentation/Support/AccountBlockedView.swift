import SwiftUI

/// A11: shown from `RootView` instead of `MainTabView` whenever the signed-in
/// user's `accountStatus` isn't `.active` — same "unmissable full-screen gate,
/// nowhere else to go" shape as `ForceUpdateView`, just keyed off account
/// state instead of app config. Calm, non-accusatory copy on purpose: most
/// blocks are disputes/fraud reviews, not confirmed wrongdoing.
struct AccountBlockedView: View {
    let status: User.AccountStatus
    let onSignOut: () -> Void
    @State private var showingContactSupport = false

    var body: some View {
        ZStack {
            Theme.heroGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)

                Text(title)
                    .font(.brandTitle)
                    .brandDisplayText()
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.brandBody)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    Haptics.tap()
                    showingContactSupport = true
                } label: {
                    Text("Contact support")
                        .font(.brandHeadline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 32)
                .padding(.top, 8)

                Button("Sign out", action: onSignOut)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
        .sheet(isPresented: $showingContactSupport) {
            ContactSupportView(subjectPlaceholder: "Question about my account")
        }
    }

    private var title: String {
        switch status {
        case .active: return "" // unreachable — RootView only shows this off .active
        case .blocked: return "Your account is on hold"
        case .deactivated: return "This account is deactivated"
        }
    }

    private var message: String {
        switch status {
        case .active: return ""
        case .blocked: return "We've paused access to your account while our team looks into something. This is usually resolved quickly — reach out and we'll help."
        case .deactivated: return "This account was deactivated. If you think this is a mistake, contact our support team and we'll sort it out."
        }
    }
}

#Preview {
    AccountBlockedView(status: .blocked, onSignOut: {})
}
