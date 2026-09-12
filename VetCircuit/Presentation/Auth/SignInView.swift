import SwiftUI
import AuthenticationServices

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
            errorMessage = error.localizedDescription
        }
    }

    func verifyOTP() async -> User? {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            return try await authRepository.verifyOTP(phone: phone, code: otp)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func handleAppleSignIn(result: Result<ASAuthorization, Error>) async -> User? {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
            return nil
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple sign-in failed."
                return nil
            }
            do {
                return try await authRepository.signInWithApple(identityToken: token, nonce: UUID().uuidString)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
    }
}

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = SignInViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "pawprint.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                    Text("VetCircuit")
                        .font(.largeTitle.bold())
                    Text("Home vet visits, scheduled around your neighborhood.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    Task {
                        if let user = await viewModel.handleAppleSignIn(result: result) {
                            session.currentUser = user
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Divider().padding(.vertical, 4)

                VStack(spacing: 12) {
                    TextField("Phone number", text: $viewModel.phone)
                        .keyboardType(.phonePad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Phone number")

                    if viewModel.isOTPSent {
                        TextField("Enter OTP", text: $viewModel.otp)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("One-time passcode")

                        PrimaryButton(title: "Verify & Continue", isLoading: viewModel.isLoading) {
                            Task {
                                if let user = await viewModel.verifyOTP() {
                                    session.currentUser = user
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

                Spacer()
                Spacer()
            }
            .padding(24)
        }
    }
}

#Preview {
    SignInView().environment(SessionStore())
}
