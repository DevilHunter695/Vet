import SwiftUI

@Observable
@MainActor
final class ProfileViewModel {
    var pets: [Pet] = []
    var subscription: Subscription?
    var errorMessage: String?
    var newPetName: String = ""
    var newPetSpecies: Pet.Species = .dog
    var loyaltyAccount: LoyaltyAccount?
    /// Header summary figures. Kept on the view model rather than fetched by
    /// the header view itself so the whole screen settles in one pass instead
    /// of each tile popping in separately.
    var walletBalanceMinorUnits: Int = 0
    var completedVisitCount: Int = 0
    var upcomingVisit: Visit?

    private let getWalletBalanceUseCase = DependencyContainer.shared.getWalletBalanceUseCase()
    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()

    /// Pets that still count as "yours" today — archived ones stay reachable
    /// in the list below but shouldn't inflate the headline count.
    var activePets: [Pet] { pets.filter { !$0.isArchived } }

    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let subscriptionRepository = DependencyContainer.shared.subscriptionRepository
    private let subscribeToPlanUseCase = DependencyContainer.shared.subscribeToPlanUseCase()
    private let getLoyaltyAccountUseCase = DependencyContainer.shared.getLoyaltyAccountUseCase()
    private let renewalReminderUseCase = DependencyContainer.shared.renewalReminderUseCase()
    private let dunningStatusUseCase = DependencyContainer.shared.dunningStatusUseCase()
    private let drainLifecycleNotificationQueueUseCase = DependencyContainer.shared.drainLifecycleNotificationQueueUseCase()

    func load(userId: UUID, currentUser: User?) async {
        do {
            // N3: same routine-screen-load pattern as H4/I8/F4 — drain any
            // vaccination-due/renewal/dormant/abandoned-cart pushes the
            // lifecycle-notifications Edge Function queued server-side.
            // Best-effort: a failure here shouldn't block the rest of the
            // profile load.
            if let currentUser {
                try? await drainLifecycleNotificationQueueUseCase.execute(user: currentUser)
            }
            // includeArchived: this list is the pet-management screen, not a
            // booking picker — an archived pet still needs to be visible so
            // its owner can open its record or bring it back (B8).
            pets = try await managePetsUseCase.list(ownerId: userId, includeArchived: true)
            subscription = try await subscriptionRepository.currentSubscription(userId: userId)
            loyaltyAccount = try await getLoyaltyAccountUseCase.execute(userId: userId)
            // Best-effort: a wallet or history hiccup should degrade the
            // summary tiles, never fail the whole profile load.
            walletBalanceMinorUnits = (try? await getWalletBalanceUseCase.balance(userId: userId)) ?? 0
            let history = (try? await getVisitHistoryUseCase.execute(userId: userId)) ?? []
            completedVisitCount = history.filter { $0.status == .completed }.count
            upcomingVisit = history
                .filter { $0.scheduledAt > .now && $0.status.isUpcoming }
                .min { $0.scheduledAt < $1.scheduledAt }
            if let subscription {
                // H5: the profile tab is a routine, frequently-visited screen
                // (same trigger-point pattern F4/I8 used on VisitHistoryView),
                // so check here whether this subscriber's grace period has
                // quietly expired and downgrade promptly rather than only
                // when they happen to open subscription management.
                if try await dunningStatusUseCase.resolveIfGraceExpired(subscriptionId: subscription.id) {
                    self.subscription = try? await subscriptionRepository.currentSubscription(userId: userId)
                }
                if subscription.status == .active {
                    PushNotificationManager.shared.scheduleRenewalReminder(subscription: subscription)
                    // H4: same pattern — best-effort T-7/T-1 reminder push,
                    // deduped locally so it only fires once per stage per day.
                    if let currentUser {
                        try? await renewalReminderUseCase.execute(user: currentUser, subscription: subscription)
                    }
                }
            }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func addPet(ownerId: UUID) async {
        guard !newPetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let pet = Pet(id: UUID(), ownerId: ownerId, name: newPetName, species: newPetSpecies, breed: nil, dateOfBirth: nil)
            let added = try await managePetsUseCase.add(pet)
            withAnimation(Theme.springSoft) { pets.append(added) }
            newPetName = ""
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// B1/B8: "delete" from the pet list is a swipe-to-archive, never a hard
    /// delete — a pet's visit/vaccination/prescription history must survive.
    /// Uses `.other` as the reason since a swipe gesture carries no context;
    /// `PetDetailView` lets the owner pick deceased/rehomed/other explicitly.
    func archivePet(_ pet: Pet) async {
        do {
            let archived = try await managePetsUseCase.archive(pet, reason: .other)
            withAnimation(Theme.springQuick) {
                if let index = pets.firstIndex(where: { $0.id == pet.id }) { pets[index] = archived }
            }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func subscribe(userId: UUID, plan: Subscription.PlanType, seatCount: Int = 1) async -> URL? {
        try? await subscribeToPlanUseCase.execute(userId: userId, plan: plan, seatCount: seatCount)
    }
}

struct ProfileView: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @State private var viewModel = ProfileViewModel()
    @State private var checkoutURL: URL?
    // RawRepresentable (String) enums are stored directly by @AppStorage, so
    // there's no need for a Binding(get:set:) shim built in the view body to
    // bridge a raw-string key to the enum the pickers below actually bind to.
    @AppStorage("vc.selected_vertical") private var selectedVertical: Vertical = .vet
    @AppStorage("vc.appearance") private var appearance: AppearanceOption = .system
    // A10: UserDefaults-backed directly (not routed through the view model) —
    // this is a local device preference, not server state; RootView reads
    // the same key via `BiometricLockSetting`.
    @AppStorage("vc.biometric_lock_enabled") private var biometricLockEnabled: Bool = false

    var body: some View {
        // N7: path driven by the shared Router, mirroring VisitHistoryView —
        // lets `vetcircuit://household` push straight to HouseholdView
        // instead of only switching to this tab.
        NavigationStack(path: Bindable(router).profilePath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ScrollOffsetProbe()
                    if let user = session.currentUser {
                        ProfileHeroCard(
                            user: user,
                            tier: viewModel.loyaltyAccount?.tier,
                            tierColor: viewModel.loyaltyAccount.map { tierColor($0.tier) } ?? Theme.primary
                        )
                        .appearAnimation()

                        summaryTiles
                            .appearAnimation(delay: 0.04)
                    }

                    if let visit = viewModel.upcomingVisit {
                        NextVisitCard(visit: visit) {
                            // Hands off to the Visits tab, which owns the
                            // visit-detail destination.
                            router.selectedTab = .visits
                        }
                        .appearAnimation(delay: 0.08)
                    }

                    if let loyalty = viewModel.loyaltyAccount {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(
                                title: "Rewards",
                                subtitle: rewardsSubtitle(loyalty),
                                systemImage: "star.circle.fill"
                            )
                            LoyaltyProgressCard(
                                account: loyalty,
                                color: tierColor(loyalty.tier),
                                progress: tierProgress(loyalty),
                                pointsToNextTier: pointsToNextTier(loyalty)
                            )
                            .padding(16)
                            .glassCard()
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    subscriptionSection

                    petsSection

                    ProfileGroup(title: "Your account", systemImage: "person.text.rectangle") {
                        ProfileLinkRow(title: "Edit profile", subtitle: "Name, email, photo", systemImage: "person.crop.circle") { EditProfileView() }
                        ProfileLinkRow(title: "Wallet", subtitle: CurrencyFormatter.rupees(viewModel.walletBalanceMinorUnits) + " available", systemImage: "indianrupeesign.circle") { WalletBalanceView() }
                        ProfileLinkRow(title: "Addresses", subtitle: "Where your vet comes to", systemImage: "mappin.and.ellipse") { AddressListView() }
                        ProfileLinkRow(title: "Payment methods", subtitle: "Cards & UPI", systemImage: "creditcard") { PaymentMethodsView() }
                        ProfileLinkRow(title: "Household", subtitle: "Share pets & bookings", systemImage: "person.2") { HouseholdView() }
                        ProfileLinkRow(title: "Recurring bookings", systemImage: "repeat") { RecurringBookingsView() }
                        ProfileLinkRow(title: "Invite friends", subtitle: "Both of you get credit", systemImage: "gift", tint: Theme.accent) { ReferralView() }
                    }

                    preferencesSection

                    ProfileGroup(title: "Support & legal", systemImage: "lifepreserver") {
                        ProfileLinkRow(title: "Help centre", systemImage: "questionmark.circle") { HelpCenterView() }
                        ProfileLinkRow(title: "Contact support", systemImage: "bubble.left.and.text.bubble.right") { ContactSupportView() }
                        ProfileLinkRow(title: "My tickets", systemImage: "tray.full") { MyTicketsView() }
                        ProfileLinkRow(title: "Privacy & consent", subtitle: "What we store and why", systemImage: "hand.raised") { PrivacyConsentView() }
                        ProfileLinkRow(title: "Privacy Policy", systemImage: "doc.text") { PrivacyPolicyView() }
                        ProfileLinkRow(title: "Terms of Service", systemImage: "doc.plaintext") { TermsOfServiceView() }
                    }

                    // Grouped: a ViewBuilder takes at most ten children, and
                    // the stack above is already at that limit.
                    Group {
                        if let error = viewModel.errorMessage {
                            ErrorBanner(message: error)
                        }

                        SecondaryButton(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Haptics.warning()
                            Task { await session.signOut() }
                        }

                        Text("VetCircuit \(appVersionText)")
                            .font(.brandCaption2)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
            // A vertical-axis TextField has no Return key to dismiss with -
            // Return inserts a newline - and the app has no keyboard toolbar, so
            // without this a keyboard opened here covers the pinned action bar
            // with no way to put it away.
            .scrollDismissesKeyboard(.interactively)
            .floatingTabBarScroll()
            .auroraScreenBackground()
            .navigationTitle("Profile")
            // The bar keeps its large title but loses its background, so
            // content runs to the top of the display and passes under the
            // title rather than stopping below a hairline. Apple Music's
            // screens read as starting at the top edge for exactly this
            // reason — there is no reserved strip, only a title sitting on
            // the content.
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .household:
                    HouseholdView()
                case .visitDetail, .chat:
                    // Not this tab's routes — Router only ever pushes these
                    // onto visitsPath, never profilePath.
                    EmptyView()
                }
            }
            .animation(Theme.crossFade, value: viewModel.loyaltyAccount?.points)
            .refreshable {
                if let user = session.currentUser { await viewModel.load(userId: user.id, currentUser: user) }
            }
            .task { if let user = session.currentUser { await viewModel.load(userId: user.id, currentUser: user) } }
            .sheet(item: $checkoutURL) { url in
                CheckoutWebView(url: url)
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    /// Four figures that answer "how am I doing here?" without making the
    /// user open four screens. A prototype shows navigation; a finished
    /// product shows state.
    private var summaryTiles: some View {
        // One divided strip rather than four separate cards: see `StatStrip`
        // for why. Four figures share the width comfortably here because the
        // strip is shallow and the value font is a callout, not a title — the
        // old two-column grid needed the extra room only because each figure
        // was trying to be a headline.
        StatStrip(items: [
            .init(
                value: CurrencyFormatter.rupees(viewModel.walletBalanceMinorUnits),
                label: "Wallet", systemImage: "indianrupeesign.circle.fill", tint: Theme.emerald
            ),
            .init(
                value: "\(viewModel.loyaltyAccount?.points ?? 0)",
                label: "Points", systemImage: "star.fill",
                tint: viewModel.loyaltyAccount.map { tierColor($0.tier) } ?? Theme.goldTier
            ),
            .init(
                value: "\(viewModel.activePets.count)",
                label: viewModel.activePets.count == 1 ? "Pet" : "Pets",
                systemImage: "pawprint.fill", tint: Theme.primary
            ),
            .init(
                value: "\(viewModel.completedVisitCount)",
                label: "Visits", systemImage: "checkmark.seal.fill", tint: Theme.primaryLight,
                accessibilityName: "Visits done"
            )
        ])
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Membership", systemImage: "crown.fill")

            if let subscription = viewModel.subscription, subscription.status != .cancelled {
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subscription.planType.displayName)
                                .font(.brandTitle3)
                            Text("Renews \(subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.brandCaption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        TagChip(
                            text: subscription.status.rawValue.capitalized,
                            systemImage: subscription.status == .active ? "checkmark.circle.fill" : "pause.circle.fill",
                            tint: subscription.status == .active ? Theme.success : Theme.warning
                        )
                    }
                    if subscription.planType.isBulk {
                        GlassSeam()
                        InfoRow(label: "Seats", value: "\(subscription.seatCount)", systemImage: "person.3", isMonospaced: true)
                    }
                    NavigationLink {
                        ManageSubscriptionView()
                    } label: {
                        HStack {
                            Text("Manage membership").font(.brandCaption)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(Theme.primary)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(16)
                .featuredGlassCard()
            } else {
                // H1: full inclusions + fair-use limits shown before purchase,
                // rather than a bare "Subscribe" button.
                NavigationLink {
                    PlanCatalogView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(Theme.emeraldLight)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Join VetCircuit Care").font(.brandHeadline)
                            Text("Free visits, priority slots and member pricing from \(CurrencyFormatter.rupees(PlanCatalogEntry.lowestHeadlineMonthlyMinorUnits))/month.")
                                .font(.brandCaption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(16)
                    .featuredGlassCard(tint: Theme.emerald)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .animation(Theme.crossFade, value: viewModel.subscription?.id)
    }

    @ViewBuilder
    private var petsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Your pets",
                subtitle: viewModel.pets.isEmpty ? "Add one to start booking" : "\(viewModel.activePets.count) in your care",
                systemImage: "pawprint.fill"
            )

            if viewModel.pets.isEmpty {
                CalloutNote(
                    text: "Add your first pet below — their weight, vaccinations and prescriptions all live in one record the vet can read before arriving.",
                    systemImage: "pawprint.circle.fill"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.pets) { pet in
                            NavigationLink {
                                PetDetailView(pet: pet)
                            } label: {
                                PetCard(pet: pet)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                // The card row overflows its container horizontally by
                // design; without this the scroll view clips the shadows.
                .scrollClipDisabled()
            }

            AddPetField(
                name: $viewModel.newPetName,
                species: $viewModel.newPetSpecies,
                onAdd: {
                    Task { if let user = session.currentUser { await viewModel.addPet(ownerId: user.id) } }
                }
            )
        }
    }

    @ViewBuilder
    private var preferencesSection: some View {
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
                ProfileLinkRow(title: "Notification centre", systemImage: "tray") { NotificationCenterView() }
            }
        }
    }

    private func rewardsSubtitle(_ account: LoyaltyAccount) -> String {
        let remaining = pointsToNextTier(account)
        guard remaining > 0 else { return "You're at the top tier" }
        return "\(remaining) points to the next tier"
    }

    /// Mirrors `LoyaltyAccount.Tier.forPoints` thresholds (200 / 600) so the
    /// progress bar and the tier the server assigns never disagree.
    private func pointsToNextTier(_ account: LoyaltyAccount) -> Int {
        switch account.tier {
        case .bronze: return max(0, 200 - account.points)
        case .silver: return max(0, 600 - account.points)
        case .gold: return 0
        }
    }

    private func tierColor(_ tier: LoyaltyAccount.Tier) -> Color {
        switch tier {
        case .bronze: return Theme.bronzeTier
        case .silver: return Theme.silverTier
        case .gold: return Theme.goldTier
        }
    }

    private func tierProgress(_ account: LoyaltyAccount) -> CGFloat {
        let raw: CGFloat
        switch account.tier {
        case .bronze: raw = CGFloat(account.points) / 200
        case .silver: raw = CGFloat(account.points - 200) / 400
        case .gold: raw = 1
        }
        return min(max(raw, 0), 1)
    }
}

private struct LoyaltyProgressCard: View {
    let account: LoyaltyAccount
    let color: Color
    let progress: CGFloat
    let pointsToNextTier: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(account.points)")
                    .font(.brandMono(.title, weight: .bold))
                    .foregroundStyle(color)
                    .brandDisplayText()
                Text("points")
                    .font(.brandCallout)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                TierBadge(tier: account.tier, color: color)
            }

            ProgressTrack(color: color, progress: progress)
                .frame(height: 8)
                .accessibilityHidden(true)

            // The section header above already says which tier this is, so
            // this line only carries what it does not. It used to repeat
            // "You're at the top tier" verbatim and then run on.
            Text(
                pointsToNextTier > 0
                    ? "\(pointsToNextTier) more to the next tier"
                    : "Points convert to wallet credit at checkout"
            )
            .font(.brandCaption2)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(progress * 100)) percent to next tier")
    }
}

private struct TierBadge: View {
    let tier: LoyaltyAccount.Tier
    let color: Color

    var body: some View {
        Text(tier.rawValue.capitalized)
            .font(.brandCaption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct ProgressTrack: View {
    let color: Color
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.7), color],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    // A zero-width capsule renders as a dot; clamp to nothing
                    // so an empty bar looks empty rather than broken.
                    .frame(width: max(0, geo.size.width * progress))
                    .shadow(color: color.opacity(0.5), radius: 6, y: 2)
            }
        }
        .allowsHitTesting(false)
        .animation(Theme.springSoft, value: progress)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    ProfileView().environment(SessionStore()).environment(Router())
}


// MARK: - Profile screen components

/// The identity card at the top of the tab: photo (or the paw mascot), name,
/// phone, and the loyalty tier, over a brand-tinted glass surface. This is the
/// first thing on the screen, so it carries the aurora rather than a grey row.
/// The header, deliberately not shaped like the cards below it.
///
/// Every element on this screen used to be the same width, the same corner
/// radius and roughly the same height, which is what made the screen read as
/// one grey texture no matter how good the material was. The fix is not more
/// glass — it is rhythm: one tall, bright, full-bleed element at the top that
/// nothing below it imitates.
private struct ProfileHeroCard: View {
    let user: User
    let tier: LoyaltyAccount.Tier?
    let tierColor: Color

    private let avatarSize: CGFloat = 92

    var body: some View {
        VStack(spacing: 14) {
            avatar
                .allowsHitTesting(false)

            VStack(spacing: 6) {
                Text(user.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .brandDisplayText()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if let phone = user.phone {
                    Text(phone)
                        .font(.brandCallout)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let tier {
                    TagChip(text: "\(tier.rawValue.capitalized) member", systemImage: "star.fill", tint: tierColor)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background {
            // The light lives *behind* the header rather than being a tint on
            // it, so the glass above still reads as glass instead of as a
            // coloured panel.
            ZStack {
                Circle()
                    .fill(Theme.primary.opacity(0.38))
                    .frame(width: 260, height: 260)
                    .blur(radius: 90)
                    .offset(x: -70, y: -60)
                Circle()
                    .fill((tier.map { _ in tierColor } ?? Theme.emerald).opacity(0.30))
                    .frame(width: 220, height: 220)
                    .blur(radius: 85)
                    .offset(x: 80, y: 60)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .allowsHitTesting(false)
        }
        .featuredGlassCard(cornerRadius: 30)
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Theme.gradient)
                .frame(width: avatarSize, height: avatarSize)
                .shadow(color: Theme.primary.opacity(0.45), radius: 20, y: 8)

            if let photoURL = user.photoURL {
                AsyncImage(url: photoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    PawMascot(size: avatarSize, animated: false)
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.system(size: 34, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .overlay {
            // The rim light that sells the avatar as a lit object rather than
            // a flat swatch, matched to the glass edge above it.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: avatarSize, height: avatarSize)
        }
    }

    private var initials: String {
        let parts = user.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// The "what's next" card. A pet owner's single most common question on
/// opening the app is "when is the vet coming?" — answering it above the fold
/// is worth more than any amount of chrome.
private struct NextVisitCard: View {
    let visit: Visit
    let onOpen: () -> Void

    private var countdownText: String {
        let interval = visit.scheduledAt.timeIntervalSinceNow
        guard interval > 0 else { return "Starting now" }
        let hours = Int(interval / 3600)
        if hours < 1 { return "In \(max(1, Int(interval / 60))) min" }
        if hours < 24 { return "In \(hours) hr" }
        return "In \(hours / 24) day\(hours / 24 == 1 ? "" : "s")"
    }

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Next visit").brandEyebrow()
                    Spacer()
                    StatusBadge(status: visit.status)
                }
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.brandTitle3)
                        Text(countdownText)
                            .font(.brandCaption)
                            .foregroundStyle(Theme.emeraldLight)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
            .featuredGlassCard(tint: Theme.emerald)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Next visit \(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened)), \(visit.status.displayText)")
    }
}

/// A titled card that groups related navigation rows. Replaces the long,
/// undifferentiated `List` of plain `NavigationLink`s that made the screen
/// read like a settings dump rather than a product.
// Deliberately not `private`: Profile's sections were split into their own
// files (ProfilePetsSection, ProfilePreferencesSection, …) and these are the
// building blocks they share. File-private was correct while the whole screen
// lived in one file and stopped being correct the moment it did not.
struct ProfileGroup<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, systemImage: systemImage)
            VStack(spacing: 0) {
                content
            }
            .glassCard()
            // Clipping is what makes the separators work: every row draws one
            // along its bottom edge, and the last row's falls outside the
            // card's shape and simply disappears. The alternative — telling
            // each row whether it is last — means every group in the app has
            // to count its own children.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// One row inside a `ProfileGroup`. The whole row is the Button's label, so
/// the entire width is tappable — the previous plain-`List` rows relied on
/// the system's row chrome for that, which custom cards don't provide.
/// Rows highlight rather than scale. A full-width row that shrinks inside a
/// clipped card pulls away from the card's own edges and shows the background
/// through the gap; a brightness change stays inside the shape and reads as
/// the surface responding to the touch.
private struct ProfileRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// Deliberately not `private`: Profile's sections were split into their own
// files (ProfilePetsSection, ProfilePreferencesSection, …) and these are the
// building blocks they share. File-private was correct while the whole screen
// lived in one file and stopped being correct the moment it did not.
struct ProfileLinkRow<Destination: View>: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = Theme.primary
    // Stored as a closure, not as a built view.
    //
    // As `let destination: Destination` this was a stored property, so every
    // destination on the screen was constructed each time Profile's body ran
    // - fifteen whole screens, including their view models, to draw a list of
    // rows. And Profile's body runs again the moment the wallet balance
    // arrives, because that balance is this row's subtitle. Tapping Wallet
    // during that rebuild is how "tapped Wallet once and Wallet did not open"
    // happens, and why it is always Wallet: it is the row whose own data
    // triggers the rebuild.
    //
    // Behind a closure the destination is built when somebody navigates to
    // it. Callers are unchanged - the trailing closure is still the builder.
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .scaledIcon(15, weight: .medium)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.brandCallout).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.brandCaption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) {
                // Inset to the text column, the way iOS insets its own list
                // separators — a full-width rule cuts the icon off from its
                // label and makes the group read as unrelated strips rather
                // than one list.
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.5)
                    .padding(.leading, 60)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(title). \($0)" } ?? title)
    }
}

/// A pet, as a card rather than a line of text — species, age and the flags a
/// vet would want to know at a glance (allergies, chronic conditions), plus a
/// clear archived treatment instead of a grey word at the end of a row.
// Deliberately not `private`: Profile's sections were split into their own
// files (ProfilePetsSection, ProfilePreferencesSection, …) and these are the
// building blocks they share. File-private was correct while the whole screen
// lived in one file and stopped being correct the moment it did not.
struct PetCard: View {
    let pet: Pet

    private var ageText: String? { pet.ageText }

    private var speciesIcon: String {
        switch pet.species {
        case .dog: return "dog.fill"
        case .cat: return "cat.fill"
        case .bird: return "bird.fill"
        case .other: return "pawprint.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Theme.gradient)
                    .frame(width: 46, height: 46)
                if let photoURL = pet.photoURL {
                    AsyncImage(url: photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: speciesIcon).foregroundStyle(.white)
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
                } else {
                    Image(systemName: speciesIcon)
                        .scaledIcon(20, weight: .regular)
                        .foregroundStyle(.white)
                }
            }
            .allowsHitTesting(false)
            .opacity(pet.isArchived ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(pet.name)
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text([pet.breed, ageText].compactMap { $0 }.joined(separator: " · "))
                    .font(.brandCaption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            if pet.isArchived {
                TagChip(text: pet.archiveReason?.displayName ?? "Archived", systemImage: "archivebox", tint: Theme.neutral)
            } else if pet.allergies?.isEmpty == false {
                TagChip(text: "Allergies on file", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
            } else if let weight = pet.weightKg {
                TagChip(text: String(format: "%.1f kg", weight), systemImage: "scalemass", tint: Theme.emerald)
            } else {
                TagChip(text: "Tap to complete", systemImage: "plus.circle", tint: Theme.primary)
            }
        }
        .frame(width: 152, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 18)
        .opacity(pet.isArchived ? 0.72 : 1)
    }
}

/// Inline "add a pet" composer. Kept on the profile screen (rather than behind
/// a sheet) because adding the first pet is the step that unblocks booking.
// Deliberately not `private`: Profile's sections were split into their own
// files (ProfilePetsSection, ProfilePreferencesSection, …) and these are the
// building blocks they share. File-private was correct while the whole screen
// lived in one file and stopped being correct the moment it did not.
struct AddPetField: View {
    @Binding var name: String
    @Binding var species: Pet.Species
    let onAdd: () -> Void

    @FocusState private var isFocused: Bool

    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.primary)
                TextField("Add a pet's name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.brandCallout)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { if canAdd { add() } }
            }

            // The second question appears once the first is answered. At
            // rest this is a single field saying "add a pet" — which is what
            // it is — rather than a three-control form standing open on a
            // screen somebody came to for something else. The species picker
            // and the button have nothing to act on until there is a name.
            if canAdd {
                Picker("Species", selection: $species) {
                    ForEach(Pet.Species.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: species) { _, _ in Haptics.selection() }

                PrimaryButton(title: "Add \(name.trimmingCharacters(in: .whitespaces))", systemImage: "pawprint.fill") {
                    add()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: canAdd)
        .padding(16)
        .glassCard()
    }

    private func add() {
        guard canAdd else { return }
        isFocused = false
        onAdd()
    }
}
