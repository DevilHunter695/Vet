import SwiftUI

@Observable
@MainActor
final class SignInViewModel {
    var phone: String = ""
    var otp: String = ""
    var isOTPSent = false
    var isLoading = false
    var errorMessage: String?

    private let authRepository = DependencyContainer.shared.authRepository

    func requestOTP() async {
        errorMessage = nil
        guard phone.count >= 10 else {
            errorMessage = "Enter a valid phone number."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await authRepository.requestOTP(phone: phone)
            isOTPSent = true
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func verifyOTP() async -> User? {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            return try await authRepository.verifyOTP(phone: phone, code: otp)
        } catch {
            errorMessage = UserFacingError.message(for: error)
            return nil
        }
    }

}

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = SignInViewModel()
    @FocusState private var focusedField: Field?

    private enum Field { case phone, otp }

    var body: some View {
        NavigationStack {
            ZStack {
                // The full aurora at extra intensity — this is the one screen
                // where the background *is* the product's first impression,
                // so it gets the blue→green→black gradient with both lights
                // turned up rather than the flat hero fill.
                AuroraBackground(intensity: 1.5)
                    .environment(\.colorScheme, .dark)

                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    VStack(spacing: 14) {
                        PawMascot(size: 104)
                            .appearAnimation()

                        Text("VetCircuit")
                            .font(.brandLargeTitle)
                            .brandDisplayText()
                            .foregroundStyle(.white)
                            .appearAnimation(delay: 0.05)

                        Text("Home vet visits, scheduled\naround your neighborhood.")
                            .font(.brandBody)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .appearAnimation(delay: 0.1)
                    }

                    Spacer(minLength: 32)

                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            TextField("", text: $viewModel.phone, prompt: Text("Phone number").foregroundStyle(.white.opacity(0.6)))
                                .keyboardType(.phonePad)
                                .focused($focusedField, equals: .phone)
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                                .accessibilityLabel("Phone number")

                            if viewModel.isOTPSent {
                                TextField("", text: $viewModel.otp, prompt: Text("Enter OTP").foregroundStyle(.white.opacity(0.6)))
                                    .keyboardType(.numberPad)
                                    .focused($focusedField, equals: .otp)
                                    .foregroundStyle(.white)
                                    .padding(14)
                                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                                    .accessibilityLabel("One-time passcode")
                                    .transition(.move(edge: .top).combined(with: .opacity))

                                PrimaryButton(title: "Verify & Continue", isLoading: viewModel.isLoading) {
                                    Task {
                                        if let user = await viewModel.verifyOTP() {
                                            Haptics.success(); withAnimation(Theme.springSoft) { session.currentUser = user }
                                        }
                                    }
                                }
                            } else {
                                PrimaryButton(title: "Send OTP", isLoading: viewModel.isLoading) {
                                    Task { await viewModel.requestOTP() }
                                }
                            }

                            if let errorMessage = viewModel.errorMessage {
                                ErrorBanner(message: errorMessage)
                            }
                        }
                        .animation(Theme.springQuick, value: viewModel.isOTPSent)
                    }
                    .padding(20)
                    .glassCard(cornerRadius: 24)
                    .environment(\.colorScheme, .dark)
                    .appearAnimation(delay: 0.15)

                    Spacer(minLength: 32)
                }
                .padding(24)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onTapGesture { focusedField = nil }
        }
    }
}

#Preview {
    SignInView().environment(SessionStore())
}
