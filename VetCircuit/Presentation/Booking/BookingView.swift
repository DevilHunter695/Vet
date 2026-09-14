import SwiftUI
import UIKit

@Observable
@MainActor
final class BookingViewModel {
    let circuit: Circuit
    /// F5: the category/service/variant being booked, when known from the
    /// catalog flow — the "make this recurring" toggle only makes sense for
    /// deworming/physio (plan §F5) and needs a service+variant to recur.
    let serviceCategory: ServiceCategory?
    let serviceId: UUID?
    let variantId: UUID?
    /// K5: 1-tap follow-up preselects the same pet as the original visit —
    /// the customer never re-picks it.
    let preselectedPetId: UUID?
    var pets: [Pet] = []
    var selectedPet: Pet?
    /// F5: user's choice to also create a recurring rule alongside this booking.
    var makeRecurring = false
    var recurringCadence: RecurringBookingRule.Cadence = .monthly
    var selectedSlot: ScheduleSlot? {
        didSet {
            if selectedSlot?.id != oldValue?.id {
                bookingIdempotencyKey = UUID().uuidString
                Task { await refreshHold() }
            }
        }
    }
    var isLoading = false
    var errorMessage: String?
    var bookedVisit: Visit?
    /// E6-E10/G6: set once `confirmBooking` has started a real, quote-gated
    /// checkout — presented as a sheet; `resolveCheckout` runs when it's
    /// dismissed (success, failure, or the customer just backing out).
    var checkoutURL: URL?
    /// E8: the customer's choice at the same decision point where they'd
    /// otherwise be sent to hosted checkout — pay now (prepaid, via
    /// `checkoutURL`) or pay after the visit (cash/UPI to the vet on-site).
    var payAfterVisit = false
    /// The visit created (status `.requested`, unpaid) while checkout is in
    /// flight — kept around so a dismissed/failed/pending checkout can be
    /// resumed instead of the booking silently vanishing.
    private(set) var pendingVisit: Visit?
    private(set) var canRetryPayment = false
    private var lastQuote: Quote?
    private var retryAttempts = 0
    /// E7: a 10-min hold placed the moment a slot is picked, so it can't be
    /// sold to someone else while this customer is still filling out the form.
    private(set) var activeHold: SlotHold?
    private(set) var holdSecondsRemaining: Int?
    private var holdTimer: Task<Void, Never>?
    private var currentUserId: UUID?
    /// E10: kept only so `confirmBooking` can send a "visit confirmed"
    /// receipt notification without re-fetching the user.
    private var currentUser: User?
    /// Generated once per booking attempt and reused across retries (plan
    /// §7.1: "every mutating endpoint takes an idempotency key") — a double
    /// tap or a retry after a dropped response returns the same visit
    /// instead of creating a second one.
    private var bookingIdempotencyKey = UUID().uuidString

    private let bookVisitUseCase = DependencyContainer.shared.bookVisitUseCase()
    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let holdSlotUseCase = DependencyContainer.shared.holdSlotUseCase()
    private let slotHoldRepository = DependencyContainer.shared.slotHoldRepository
    private let manageRecurringBookingUseCase = DependencyContainer.shared.manageRecurringBookingUseCase()
    /// E10: receipt notification (push, or SMS fallback per J8's policy)
    /// once a booking is confirmed.
    private let sendTransactionalNotificationUseCase = DependencyContainer.shared.sendTransactionalNotificationUseCase()
    /// E6/E8/G6: the real quote -> checkout -> confirmed-visit pipeline.
    private let getQuoteUseCase = DependencyContainer.shared.getQuoteUseCase()
    private let bookingCheckoutUseCase = DependencyContainer.shared.bookingCheckoutUseCase()
    private let retryPaymentUseCase = DependencyContainer.shared.retryPaymentUseCase()
    private let paymentRepository = DependencyContainer.shared.paymentRepository

    /// F5's toggle is offered only for the categories the plan calls out —
    /// deworming (monthly) and physio (weekly) — everything else defaults
    /// the toggle away rather than showing a control that doesn't apply.
    var offersRecurring: Bool {
        (serviceCategory == .deworming || serviceCategory == .physioSession) && serviceId != nil && variantId != nil
    }

    init(circuit: Circuit, serviceCategory: ServiceCategory? = nil, serviceId: UUID? = nil, variantId: UUID? = nil, preselectedPetId: UUID? = nil) {
        self.circuit = circuit
        self.serviceCategory = serviceCategory
        self.serviceId = serviceId
        self.variantId = variantId
        self.preselectedPetId = preselectedPetId
        self.recurringCadence = serviceCategory == .physioSession ? .weekly : .monthly
    }

    private func refreshHold() async {
        holdTimer?.cancel()
        if let previousHold = activeHold { try? await slotHoldRepository.releaseHold(id: previousHold.id) }
        activeHold = nil
        holdSecondsRemaining = nil
        guard let slot = selectedSlot, let userId = currentUserId else { return }
        do {
            let hold = try await holdSlotUseCase.execute(circuitId: circuit.id, slotId: slot.id, userId: userId)
            activeHold = hold
            startCountdown(until: hold.expiresAt)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCountdown(until expiresAt: Date) {
        holdTimer = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = Int(expiresAt.timeIntervalSinceNow)
                self?.holdSecondsRemaining = max(0, remaining)
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func releaseHold() {
        holdTimer?.cancel()
        if let hold = activeHold { Task { try? await slotHoldRepository.releaseHold(id: hold.id) } }
        activeHold = nil
        holdSecondsRemaining = nil
    }

    func loadPets(user: User) async {
        currentUserId = user.id
        currentUser = user
        let ownerId = user.id
        do {
            pets = try await managePetsUseCase.list(ownerId: ownerId)
            selectedPet = preselectedPetId.flatMap { id in pets.first { $0.id == id } } ?? pets.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// E6/E8/G6: a real, service-priced quote can only be assembled when the
    /// catalog flow handed this screen a specific service + variant (F5's
    /// same precondition). Without that context (the generic "tap a circuit"
    /// entry point from `CircuitsListView`, which never picks a service),
    /// there's nothing to price against a signed quote — that path keeps the
    /// pre-existing direct-book-no-payment behavior as a named, narrower
    /// remaining gap rather than silently mis-pricing something.
    var canCheckoutWithPayment: Bool { serviceId != nil && variantId != nil }

    /// One primary action per screen: confirm the booking once pet + slot are chosen.
    func confirmBooking() async {
        guard let pet = selectedPet, let slot = selectedSlot else {
            errorMessage = "Choose a pet and a time slot to continue."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if canCheckoutWithPayment, let serviceId, let variantId, let userId = currentUserId {
                // E6: a real signed quote for exactly this pet+service+slot —
                // the cart here is a throwaway in-memory value (never saved
                // to `carts`); `GetQuoteUseCase` only needs its shape.
                let cart = Cart(
                    id: UUID(), userId: userId, addressId: nil, circuitId: circuit.id, slotId: slot.id,
                    items: [CartItem(id: UUID(), serviceId: serviceId, variantId: variantId, petIds: [pet.id])]
                )
                let quote = try await getQuoteUseCase.execute(cart: cart)
                lastQuote = quote
                if payAfterVisit {
                    // E8: booked and confirmed immediately — no hosted
                    // checkout, no webhook to wait on.
                    let visit = try await bookingCheckoutUseCase.startPayAfterVisit(
                        petId: pet.id, vetId: circuit.vetId, circuitId: circuit.id, slot: slot,
                        quote: quote, idempotencyKey: bookingIdempotencyKey,
                        serviceId: serviceId, variantId: variantId
                    )
                    bookedVisit = visit
                    if let hold = activeHold { try? await slotHoldRepository.releaseHold(id: hold.id) }
                    await sendConfirmationReceipt(pet: pet)
                    await createRecurringRuleIfNeeded(pet: pet)
                } else {
                    let session = try await bookingCheckoutUseCase.start(
                        petId: pet.id, vetId: circuit.vetId, circuitId: circuit.id, slot: slot,
                        quote: quote, idempotencyKey: bookingIdempotencyKey,
                        serviceId: serviceId, variantId: variantId
                    )
                    pendingVisit = session.visit
                    checkoutURL = session.checkoutURL
                    // The hold's job ends once the visit is booked (pending payment).
                    if let hold = activeHold { try? await slotHoldRepository.releaseHold(id: hold.id) }
                }
            } else {
                bookedVisit = try await bookVisitUseCase.execute(
                    petId: pet.id, vetId: circuit.vetId, circuitId: circuit.id, slot: slot,
                    idempotencyKey: bookingIdempotencyKey
                )
                if let hold = activeHold { try? await slotHoldRepository.releaseHold(id: hold.id) }
                await sendConfirmationReceipt(pet: pet)
                await createRecurringRuleIfNeeded(pet: pet)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs once the checkout sheet is dismissed — covers the customer
    /// finishing payment, the payment failing, or them just backing out.
    func resolveCheckout() async {
        guard let visit = pendingVisit else { return }
        do {
            let (updatedVisit, outcome) = try await bookingCheckoutUseCase.resolve(visitId: visit.id, priorAttempts: retryAttempts)
            switch outcome {
            case .confirmVisit:
                pendingVisit = nil
                canRetryPayment = false
                bookedVisit = updatedVisit
                if let pet = selectedPet {
                    await sendConfirmationReceipt(pet: pet)
                    await createRecurringRuleIfNeeded(pet: pet)
                }
            case .awaitingPayment:
                pendingVisit = updatedVisit
                errorMessage = "We haven't heard back from the payment yet. This slot is still held for your booking — resume checkout below when you're ready."
            case .paymentFailed(let canRetry, let reason):
                pendingVisit = updatedVisit
                retryAttempts += 1
                canRetryPayment = canRetry
                errorMessage = reason ?? "That payment didn't go through."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// G3: re-opens checkout for the same pending visit, gated by
    /// `PaymentRetryPolicy` via `RetryPaymentUseCase`.
    func retryCheckout() async {
        guard let visit = pendingVisit, let quote = lastQuote else { return }
        guard !quote.isExpired else {
            errorMessage = "This price quote has expired — go back and start the booking again for a fresh price."
            canRetryPayment = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let paymentId = try await paymentRepository.latestPaymentId(forVisit: visit.id) else {
                errorMessage = "Couldn't find the previous payment attempt — please start the booking again."
                return
            }
            checkoutURL = try await retryPaymentUseCase.execute(visitId: visit.id, paymentId: paymentId, quote: quote, priorAttempts: retryAttempts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// E10: "order confirmation" receipt — push if available, else the J8
    /// SMS-fallback policy decides (never a blocking failure: the booking
    /// itself already succeeded by the time this runs).
    private func sendConfirmationReceipt(pet: Pet) async {
        guard let user = currentUser, let visit = bookedVisit else { return }
        let when = visit.scheduledAt.formatted(date: .abbreviated, time: .shortened)
        _ = try? await sendTransactionalNotificationUseCase.execute(
            user: user, category: .visitConfirmed,
            body: "Your visit for \(pet.name) is confirmed for \(when)."
        )
    }

    /// F5: best-effort — a failure here shouldn't undo an otherwise
    /// successful booking, just leave the customer without the rule.
    private func createRecurringRuleIfNeeded(pet: Pet) async {
        guard makeRecurring, offersRecurring, let serviceId, let variantId, let visit = bookedVisit else { return }
        let next = RecurrenceScheduler.nextOccurrence(after: visit.scheduledAt, cadence: recurringCadence)
        _ = try? await manageRecurringBookingUseCase.execute(
            userId: visit.userId, petId: pet.id, serviceId: serviceId, variantId: variantId,
            circuitId: circuit.id, cadence: recurringCadence, firstOccurrenceAt: next
        )
    }
}

struct BookingView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel: BookingViewModel
    @State private var showingWaiver = false
    @State private var hasAcceptedWaiver = false
    private let manageConsentUseCase = DependencyContainer.shared.manageConsentUseCase()

    init(circuit: Circuit, serviceCategory: ServiceCategory? = nil, serviceId: UUID? = nil, variantId: UUID? = nil, preselectedPetId: UUID? = nil) {
        _viewModel = State(initialValue: BookingViewModel(circuit: circuit, serviceCategory: serviceCategory, serviceId: serviceId, variantId: variantId, preselectedPetId: preselectedPetId))
    }

    private func confirmBookingTapped() {
        guard hasAcceptedWaiver else {
            Haptics.tap()
            showingWaiver = true
            return
        }
        Task { await viewModel.confirmBooking() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let vet = viewModel.circuit.vet {
                    NavigationLink {
                        VetDetailView(vet: vet, clusterArea: viewModel.circuit.clusterArea)
                    } label: {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(vet.name).font(.title3.bold()).foregroundStyle(.primary)
                                    // L3: a verified badge here, not just in the list row — this
                                    // is the last screen before money changes hands.
                                    VerifiedBadge(status: vet.verificationStatus)
                                }
                                Text(viewModel.circuit.clusterArea).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(PressableStyle())
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Veterinarian").font(.title3.bold())
                            Text(viewModel.circuit.clusterArea).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Which pet?").font(.headline)
                    if viewModel.pets.isEmpty {
                        Text("Add a pet in your profile first.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.pets.enumerated()), id: \.element.id) { index, pet in
                            SelectableRow(title: "\(pet.name) · \(pet.species.rawValue.capitalized)",
                                          isSelected: viewModel.selectedPet?.id == pet.id) {
                                viewModel.selectedPet = pet
                            }
                            .appearAnimation(delay: Theme.staggerDelay(index))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick a time slot").font(.headline)
                    ForEach(Array(viewModel.circuit.schedule.filter(\.isAvailable).enumerated()), id: \.element.id) { index, slot in
                        SelectableRow(
                            title: slot.startTime.formatted(date: .abbreviated, time: .shortened),
                            subtitle: "\(slot.remainingCapacity) spot\(slot.remainingCapacity == 1 ? "" : "s") left",
                            isSelected: viewModel.selectedSlot?.id == slot.id
                        ) {
                            viewModel.selectedSlot = slot
                        }
                        .appearAnimation(delay: Theme.staggerDelay(index))
                    }
                }

                if viewModel.offersRecurring {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Make this recurring", isOn: $viewModel.makeRecurring.animation(Theme.springQuick))
                                .font(.brandBody.bold())
                            if viewModel.makeRecurring {
                                Picker("Repeats", selection: $viewModel.recurringCadence) {
                                    ForEach(RecurringBookingRule.Cadence.allCases, id: \.self) { cadence in
                                        Text(cadence.displayName).tag(cadence)
                                    }
                                }
                                .pickerStyle(.segmented)
                                Text("We'll set up a \(viewModel.recurringCadence.displayName.lowercased()) reminder — booking the next visit each cycle still needs confirming.")
                                    .font(.brandCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if viewModel.canCheckoutWithPayment {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How do you want to pay?").font(.brandBody.bold())
                            SelectableRow(title: "Pay now", subtitle: "UPI, card, netbanking or wallet", isSelected: !viewModel.payAfterVisit) {
                                viewModel.payAfterVisit = false
                            }
                            SelectableRow(title: "Pay after visit", subtitle: "Cash or UPI to the vet on-site", isSelected: viewModel.payAfterVisit) {
                                viewModel.payAfterVisit = true
                            }
                        }
                    }
                }

                if let seconds = viewModel.holdSecondsRemaining {
                    Label("This slot is held for you — \(seconds / 60):\(String(format: "%02d", seconds % 60))",
                          systemImage: "clock.badge.checkmark")
                        .font(.brandCaption)
                        .foregroundStyle(Theme.inProgress)
                        .transition(.opacity)
                }

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                    if viewModel.canRetryPayment {
                        PrimaryButton(title: "Retry payment", isLoading: viewModel.isLoading) {
                            Task { await viewModel.retryCheckout() }
                        }
                    }
                }

                PrimaryButton(title: viewModel.canCheckoutWithPayment ? (viewModel.payAfterVisit ? "Confirm booking — pay after visit" : "Get price & pay") : "Confirm booking", isLoading: viewModel.isLoading) {
                    confirmBookingTapped()
                }
            }
            .padding()
        }
        .navigationTitle("Book visit")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let user = session.currentUser {
                await viewModel.loadPets(user: user)
                hasAcceptedWaiver = (try? await manageConsentUseCase.hasAcceptedLiabilityWaiver(userId: user.id)) ?? false
            }
        }
        .navigationDestination(item: $viewModel.bookedVisit) { visit in
            BookingConfirmedView(visit: visit)
        }
        .sheet(item: $viewModel.checkoutURL, onDismiss: { Task { await viewModel.resolveCheckout() } }) { url in
            CheckoutWebView(url: url)
        }
        .animation(Theme.crossFade, value: viewModel.holdSecondsRemaining)
        .onDisappear {
            if viewModel.bookedVisit == nil { viewModel.releaseHold() }
        }
        .sheet(isPresented: $showingWaiver) {
            if let user = session.currentUser {
                LiabilityWaiverView(userId: user.id) {
                    hasAcceptedWaiver = true
                    Task { await viewModel.confirmBooking() }
                }
            }
        }
    }
}

private struct SelectableRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(Theme.springQuick) { action() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.brandBody)
                    if let subtitle {
                        Text(subtitle).font(.brandCaption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AnyShapeStyle(Theme.accentSoft) : AnyShapeStyle(Color(.secondarySystemBackground)))
            )
        }
        .buttonStyle(PressableStyle())
        .selectable(isSelected: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct BookingConfirmedView: View {
    let visit: Visit
    @State private var checkmarkScale: CGFloat = 0.4
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack {
            ConfettiView()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.25), lineWidth: 8)
                        .frame(width: 96, height: 96)
                        .scaleEffect(ringOpacity == 0 ? 0.6 : 1.3)
                        .opacity(1 - ringOpacity)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(.green)
                        .scaleEffect(checkmarkScale)
                }
                .onAppear {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { checkmarkScale = 1 }
                    withAnimation(.easeOut(duration: 0.9).delay(0.1)) { ringOpacity = 1 }
                }

                Text("Booking requested!").font(.brandTitle).brandDisplayText()
                Text("We'll notify you once the vet confirms your slot.")
                    .font(.brandBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // E10: order confirmation receipt was just sent (push, or SMS
                // per J8's fallback policy) — surfaced here so it isn't a
                // silent side effect the customer never sees confirmed.
                Text("A confirmation has been sent to your phone.")
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
                StatusBadge(status: visit.status)
            }
            .padding()
            .appearAnimation()
        }
        .navigationBarBackButtonHidden()
    }
}

#Preview {
    NavigationStack {
        BookingView(circuit: MockData.circuits[0]).environment(SessionStore())
    }
}
