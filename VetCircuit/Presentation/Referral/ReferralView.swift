import SwiftUI

@Observable
@MainActor
final class ReferralViewModel {
    var code: String = ""
    var isLoading = true
    var invitePhone: String = ""
    var referrals: [Referral] = []
    var isSending = false
    var errorMessage: String?

    private let sendReferralUseCase = DependencyContainer.shared.sendReferralUseCase()
    private let referralRepository = DependencyContainer.shared.referralRepository

    func load(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            code = try await referralRepository.myReferralCode(userId: userId)
            referrals = try await referralRepository.listReferrals(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendInvite(userId: UUID, referrerPhone: String?) async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            // N1: fraud guard — blocks self-referral, re-inviting the same
            // number, and a daily invite cap.
            let referral = try await sendReferralUseCase.execute(userId: userId, phone: invitePhone, referrerPhone: referrerPhone, existingReferrals: referrals)
            withAnimation(Theme.springSoft) { referrals.insert(referral, at: 0) }
            invitePhone = ""
            Haptics.success()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

/// V2: invite a friend, both get a discounted visit once they complete their first booking.
struct ReferralView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = ReferralViewModel()

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    PawMascot(size: 56, animated: false)
                    Text("Your referral code").font(.brandCaption).foregroundStyle(.secondary)
                    // An empty `code` used to render an empty pill and share
                    // a blank invite. Shimmer until it lands.
                    if viewModel.code.isEmpty {
                        ShimmerView(cornerRadius: 12)
                            .frame(width: 168, height: 44)
                    } else {
                        Text(viewModel.code)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                            .textSelection(.enabled)
                    }

                    ShareLink(item: "Join me on VetCircuit and get your first vet visit discounted! Use my code: \(viewModel.code)") {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                            .font(.brandHeadline)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(viewModel.code.isEmpty)
                    .opacity(viewModel.code.isEmpty ? 0.45 : 1)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .appearAnimation()
            }
            .listRowBackground(Color.clear)

            Section("Invite by phone") {
                HStack {
                    TextField("Friend's phone number", text: $viewModel.invitePhone)
                        .keyboardType(.phonePad)
                    Button("Invite") {
                        Haptics.tap()
                        Task { if let user = session.currentUser { await viewModel.sendInvite(userId: user.id, referrerPhone: user.phone) } }
                    }
                    .disabled(viewModel.invitePhone.isEmpty || viewModel.isSending)
                }
                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }

            Section("Your invites") {
                if viewModel.isLoading && viewModel.referrals.isEmpty {
                    ForEach(0..<2, id: \.self) { _ in
                        ShimmerView(cornerRadius: 10).frame(height: 40)
                    }
                } else if viewModel.referrals.isEmpty {
                    Text("No invites sent yet. Share your code above and you'll both get a discounted visit.")
                        .font(.brandCaption).foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.referrals) { referral in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(referral.invitedPhone ?? "Shared by link").font(.brandBody)
                                // A phone number alone says nothing about
                                // where the invite got to, or what's owed.
                                Text("\(referral.status.detail) · invited \(referral.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            TagChip(
                                text: referral.status.displayName,
                                systemImage: referral.status.symbolName,
                                tint: referral.status.tint
                            )
                        }
                    }
                }
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Invite friends")
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

#Preview {
    NavigationStack { ReferralView().environment(SessionStore()) }
}
