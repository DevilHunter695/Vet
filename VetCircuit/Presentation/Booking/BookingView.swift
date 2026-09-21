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
    /// Where the vet is being sent. The product is a home visit, and until
    /// this existed the booking carried no address at all - dispatch had only
    /// the circuit's cluster area, which is a neighbourhood, not a doorstep.
    private(set) var addresses: [Address] = []
    var selectedAddress: Address?
    var selectedPet: Pet? {
        didSet {
            if selectedPet?.id != oldValue?.id { Task { await refreshPreviewQuote() } }
        }
    }
    /// The inline "add your first pet" composer on the pet step. Telling a
    /// petless customer mid-booking to go to their profile means abandoning
    /// the flow - and the slot hold that is counting down while they do it.
    /// What's wrong, in the customer's words. Free text on purpose: somebody
    /// worried about their dog at 11pm should be able to write "not eating
    /// since yesterday, very quiet" rather than hunt through a taxonomy.
    var reason = ""

    var newPetName = ""
    var newPetSpecies: Pet.Species = .dog

    /// F5: user's choice to also create a recurring rule alongside this booking.
    var makeRecurring = false
    var recurringCadence: RecurringBookingRule.Cadence = .monthly
    var selectedSlot: ScheduleSlot? {
        didSet {
            if selectedSlot?.id != oldValue?.id {
                bookingIdempotencyKey = UUID().uuidString
                Task { await refreshHold() }
                Task { await refreshPreviewQuote() }
            }
        }
    }
    var isLoading = false
    var errorMessage: String?
    var bookedVisit: Visit?
    /// True while the app is asking the server whether a payment went
    /// through — see `resolveCheckout()`.
    var isResolvingPayment = false
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
    /// E3: the price the customer can see *before* committing. Previously the
    /// first time any number appeared was inside the hosted-checkout sheet,
    /// which is far too late to be asking someone to trust you. This is the
    /// same signed quote `confirmBooking` uses — it is re-fetched at
    /// confirmation time, so this is a preview, never the authority.
    private(set) var previewQuote: Quote?
    private(set) var isPricing = false
    private var lastQuote: Quote?
    private var retryAttempts = 0
    /// E7: a 10-min hold placed the moment a slot is picked, so it can't be
    /// sold to someone else while this customer is still filling out the form.
    private(set) var activeHold: SlotHold?
    private(set) var holdSecondsRemaining: Int?
    /// Set when a hold runs out with the customer still in the flow. The
    /// banner previously just stopped at "held for you ... 0:00" - a promise
    /// the server had already stopped keeping - and the only way to find out
    /// was to tap Confirm and get an error.
    private(set) var hasHoldExpired = false
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
    private let manageAddressesUseCase = DependencyContainer.shared.manageAddressesUseCase()
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

    /// Prices the current pet+slot selection so the total can be shown before
    /// the customer commits. Only possible on the catalog path, where a
    /// specific service+variant is known (same precondition as
    /// `canCheckoutWithPayment`); the generic "tap a circuit" path has
    /// nothing to price and says so in the UI instead of inventing a number.
    private func refreshPreviewQuote() async {
        guard canCheckoutWithPayment,
              let serviceId, let variantId,
              let pet = selectedPet, let slot = selectedSlot,
              let userId = currentUserId
        else {
            previewQuote = nil
            return
        }
        isPricing = true
        defer { isPricing = false }
        let cart = Cart(
            id: UUID(), userId: userId, addressId: selectedAddress?.id, circuitId: circuit.id, slotId: slot.id,
            items: [CartItem(id: UUID(), serviceId: serviceId, variantId: variantId, petIds: [pet.id])]
        )
        // Best-effort: a pricing hiccup hides the preview rather than
        // blocking the booking, which is still quote-gated at confirm time.
        previewQuote = try? await getQuoteUseCase.execute(cart: cart)
    }

    private func refreshHold() async {
        holdTimer?.cancel()
        hasHoldExpired = false
        if let previousHold = activeHold { try? await slotHoldRepository.releaseHold(id: previousHold.id) }
        activeHold = nil
        holdSecondsRemaining = nil
        guard let slot = selectedSlot, let userId = currentUserId else { return }
        do {
            let hold = try await holdSlotUseCase.execute(circuitId: circuit.id, slotId: slot.id, userId: userId)
            activeHold = hold
            startCountdown(until: hold.expiresAt)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func startCountdown(until expiresAt: Date) {
        holdTimer = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = Int(expiresAt.timeIntervalSinceNow)
                self?.holdSecondsRemaining = max(0, remaining)
                if remaining <= 0 {
                    self?.hasHoldExpired = true
                    self?.activeHold = nil
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Puts a fresh hold on the same slot after the previous one lapsed. The
    /// slot may be gone by now, in which case `refreshHold` surfaces that as
    /// an error rather than silently pretending the hold succeeded.
    func extendHold() async {
        hasHoldExpired = false
        await refreshHold()
    }

    func releaseHold() {
        holdTimer?.cancel()
        holdTimer = nil
        if let hold = activeHold { Task { try? await slotHoldRepository.releaseHold(id: hold.id) } }
        activeHold = nil
        holdSecondsRemaining = nil
        hasHoldExpired = false
    }

    /// `releaseHold()` fires its network call in a detached Task; inside an
    /// async booking path we want the same cleanup but awaited, so the hold is
    /// really gone before the confirmation screen appears.
    private func releaseHoldAndAwait() async {
        holdTimer?.cancel()
        holdTimer = nil
        if let hold = activeHold { try? await slotHoldRepository.releaseHold(id: hold.id) }
        activeHold = nil
        holdSecondsRemaining = nil
        hasHoldExpired = false
    }

    func reloadAddresses() async {
        guard let ownerId = currentUserId else { return }
        guard let saved = try? await manageAddressesUseCase.list(ownerId: ownerId) else { return }
        // Prefer whatever was just added: somebody who opened the composer
        // from this screen meant to use that address for this booking.
        let known = Set(addresses.map(\.id))
        addresses = saved
        selectedAddress = saved.first { !known.contains($0.id) }
            ?? selectedAddress.flatMap { current in saved.first { $0.id == current.id } }
            ?? saved.first(where: \.isDefault)
            ?? saved.first
    }

    func addPet() async {
        let trimmed = newPetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ownerId = currentUserId else { return }
        do {
            let added = try await managePetsUseCase.add(
                Pet(id: UUID(), ownerId: ownerId, name: trimmed, species: newPetSpecies,
                    breed: nil, dateOfBirth: nil)
            )
            withAnimation(Theme.springSoft) {
                pets.append(added)
                selectedPet = added
            }
            newPetName = ""
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func loadPets(user: User) async {
        currentUserId = user.id
        currentUser = user
        let ownerId = user.id
        // Best-effort: a failure to list addresses must not block a booking,
        // it just leaves the address unset the same way an account with none
        // does. The error surfaces on the pets call below if it is systemic.
        if let saved = try? await manageAddressesUseCase.list(ownerId: ownerId) {
            addresses = saved
            selectedAddress = saved.first(where: \.isDefault) ?? saved.first
        }
        do {
            pets = try await managePetsUseCase.list(ownerId: ownerId)
            selectedPet = preselectedPetId.flatMap { id in pets.first { $0.id == id } } ?? pets.first
            // `selectedPet`'s observer fires before `currentUserId` matters
            // only because it is set above; price explicitly here too so the
            // preview appears as soon as a slot is picked.
            await refreshPreviewQuote()
        } catch {
            errorMessage = UserFacingError.message(for: error)
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
                    id: UUID(), userId: userId, addressId: selectedAddress?.id, circuitId: circuit.id, slotId: slot.id,
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
                        serviceId: serviceId, variantId: variantId,
                        addressId: selectedAddress?.id, reason: reason
                    )
                    bookedVisit = visit
                    // Full release, not just the server call: this also cancels the
                    // countdown timer and clears `activeHold`. Releasing the hold
                    // server-side while leaving the timer running left the booked
                    // screen counting down to a "0:00" that meant nothing.
                    await releaseHoldAndAwait()
                    await sendConfirmationReceipt(pet: pet)
                    await createRecurringRuleIfNeeded(pet: pet)
                } else {
                    let session = try await bookingCheckoutUseCase.start(
                        petId: pet.id, vetId: circuit.vetId, circuitId: circuit.id, slot: slot,
                        quote: quote, idempotencyKey: bookingIdempotencyKey,
                        serviceId: serviceId, variantId: variantId,
                        addressId: selectedAddress?.id, reason: reason
                    )
                    pendingVisit = session.visit
                    checkoutURL = session.checkoutURL
                    // The hold's job ends once the visit is booked (pending payment).
                    // Full release, not just the server call: this also cancels the
                    // countdown timer and clears `activeHold`. Releasing the hold
                    // server-side while leaving the timer running left the booked
                    // screen counting down to a "0:00" that meant nothing.
                    await releaseHoldAndAwait()
                }
            } else {
                bookedVisit = try await bookVisitUseCase.execute(
                    petId: pet.id, vetId: circuit.vetId, circuitId: circuit.id, slot: slot,
                    idempotencyKey: bookingIdempotencyKey,
                    addressId: selectedAddress?.id, reason: reason
                )
                // Full release, not just the server call: this also cancels the
                    // countdown timer and clears `activeHold`. Releasing the hold
                    // server-side while leaving the timer running left the booked
                    // screen counting down to a "0:00" that meant nothing.
                    await releaseHoldAndAwait()
                await sendConfirmationReceipt(pet: pet)
                await createRecurringRuleIfNeeded(pet: pet)
            }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// Runs once the checkout sheet is dismissed — covers the customer
    /// finishing payment, the payment failing, or them just backing out.
    func resolveCheckout() async {
        guard let visit = pendingVisit else { return }
        // The one moment in this app where somebody has just handed over
        // money and does not yet know whether it worked. This call asks the
        // server exactly that, and it used to run with no visible state at
        // all: the sheet closed and the booking screen sat there looking
        // untouched while the answer was in flight. Silence there reads as
        // "nothing happened", which is the worst of the three things that
        // could have happened.
        isResolvingPayment = true
        defer { isResolvingPayment = false }
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
            errorMessage = UserFacingError.message(for: error)
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
            errorMessage = UserFacingError.message(for: error)
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
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: BookingViewModel
    @State private var step: BookingStep = .slot
    /// Which way the last step change went, so the transition mirrors it.
    @State private var isAdvancing = true
    @State private var hasAcceptedWaiver = false
    @State private var activeSheet: BookingSheet?
    @Environment(BookingDraft.self) private var bookingDraft
    private let manageConsentUseCase = DependencyContainer.shared.manageConsentUseCase()

    init(circuit: Circuit, serviceCategory: ServiceCategory? = nil, serviceId: UUID? = nil, variantId: UUID? = nil, preselectedPetId: UUID? = nil) {
        _viewModel = State(initialValue: BookingViewModel(circuit: circuit, serviceCategory: serviceCategory, serviceId: serviceId, variantId: variantId, preselectedPetId: preselectedPetId))
    }

    private func confirmBookingTapped() {
        guard hasAcceptedWaiver else {
            Haptics.tap()
            activeSheet = .waiver
            return
        }
        Task { await viewModel.confirmBooking() }
    }

    private var flowPlan: BookingFlowPlan {
        // Not just "more than one pet": an account with *no* pets yet still
        // needs the pet step, because that's the only place the "add a pet"
        // notice is shown. Gating this on `> 1` alone skipped straight from
        // .slot to .confirm for a petless account, and `canAdvance` on
        // .confirm requires a selected pet — so the customer was stuck on a
        // disabled "Confirm" button with a hint to "go back", with nowhere to
        // go back to that explained why.
        BookingFlowPlan(hasMultiplePets: viewModel.pets.count != 1)
    }

    private func advance() {
        if let next = flowPlan.next(after: step) {
            Haptics.tap()
            isAdvancing = true
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = next }
        } else {
            confirmBookingTapped()
        }
    }

    private func goBack() {
        guard let previous = flowPlan.previous(before: step) else { return }
        Haptics.tap()
        isAdvancing = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = previous }
    }

    /// Whether the current step has been answered. A Continue button that is
    /// always enabled teaches people to tap it and read the error; one that
    /// reflects the actual state teaches them what the screen wants.
    private var canAdvance: Bool {
        switch step {
        case .slot: return viewModel.selectedSlot != nil
        case .pet: return viewModel.selectedPet != nil
        case .confirm: return viewModel.selectedPet != nil && viewModel.selectedSlot != nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    BookingProgressBar(steps: flowPlan.steps(), current: step)
                    Text(step.title)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.textPrimary)
                    Text(step.subtitle)
                        .font(.brandCallout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 2)
                // The heading is the one thing that must not slide with the
                // step content — it is the label for the transition, so
                // animating it alongside makes the whole screen feel like it
                // jumped rather than advanced.
                .animation(.spring(response: 0.4, dampingFraction: 1.0), value: step)

                switch step {
                case .slot:
                    VStack(alignment: .leading, spacing: 20) {
                    slotPicker
                    // The hold is placed the instant a slot is picked, so the
                    // confirmation belongs on this step and not only on the
                    // ones after it.
                    if viewModel.hasHoldExpired {
                        SlotHoldExpiredBanner { Task { await viewModel.extendHold() } }
                    } else if let seconds = viewModel.holdSecondsRemaining {
                        SlotHoldBanner(secondsRemaining: seconds)
                    }
                    if let vet = viewModel.circuit.vet {
                        NavigationLink {
                            // C5's "next 7 days" availability section reads
                            // `upcomingSlots`; without this it was always empty,
                            // since a `Vet` alone carries no schedule.
                            VetDetailView(
                                vet: vet,
                                clusterArea: viewModel.circuit.clusterArea,
                                upcomingSlots: viewModel.circuit.schedule
                            )
                        } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text(vet.name).font(.title3.bold()).foregroundStyle(.primary)
                                        // L3: a verified badge here, not just in the list row — this
                                        // is the last screen before money changes hands.
                                        VerifiedBadge(status: vet.verificationStatus)
                                    }
                                    Text(viewModel.circuit.clusterArea).foregroundStyle(Theme.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityElement(children: .combine)
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Veterinarian").font(.title3.bold())
                                Text(viewModel.circuit.clusterArea).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    }
                    .transition(.bookingStep(isAdvancing: isAdvancing))

                case .pet:
                    VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Which pet?", systemImage: "pawprint.fill")
                        if viewModel.pets.isEmpty {
                            CalloutNote(
                                text: "You haven't added a pet yet. Add them here and their record will be ready for the vet before they arrive.",
                                systemImage: "pawprint.circle.fill", tint: Theme.warning
                            )
                            AddPetField(
                                name: $viewModel.newPetName,
                                species: $viewModel.newPetSpecies,
                                onAdd: { Task { await viewModel.addPet() } }
                            )
                        } else {
                            ForEach(Array(viewModel.pets.enumerated()), id: \.element.id) { index, pet in
                                SelectableRow(
                                    title: pet.name,
                                    subtitle: petSubtitle(pet),
                                    systemImage: petIcon(pet),
                                    isSelected: viewModel.selectedPet?.id == pet.id
                                ) {
                                    viewModel.selectedPet = pet
                                }
                                .appearAnimation(delay: Theme.staggerDelay(index))
                            }
                        }
                    }
                    reasonSection

                    if viewModel.hasHoldExpired {
                        SlotHoldExpiredBanner { Task { await viewModel.extendHold() } }
                    } else if let seconds = viewModel.holdSecondsRemaining {
                        SlotHoldBanner(secondsRemaining: seconds)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                        if viewModel.canRetryPayment {
                            PrimaryButton(title: "Retry payment", isLoading: viewModel.isLoading) {
                                Task { await viewModel.retryCheckout() }
                            }
                        }
                    }
                    }
                    .transition(.bookingStep(isAdvancing: isAdvancing))

                case .confirm:
                    VStack(alignment: .leading, spacing: 20) {
                    addressSection

                    if viewModel.canCheckoutWithPayment {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "How do you want to pay?", systemImage: "creditcard.fill")
                            SelectableRow(
                                title: "Pay now", subtitle: "UPI, card, netbanking or wallet",
                                systemImage: "bolt.fill", isSelected: !viewModel.payAfterVisit
                            ) {
                                viewModel.payAfterVisit = false
                            }
                            SelectableRow(
                                title: "Pay after visit", subtitle: "Cash or UPI to the vet on-site",
                                systemImage: "hand.wave.fill", isSelected: viewModel.payAfterVisit
                            ) {
                                viewModel.payAfterVisit = true
                            }
                        }

                        priceBreakdown
                    } else {
                        // Honest about the narrower path: this entry point has no
                        // service/variant to price against, so quoting anything
                        // would be a guess.
                        CalloutNote(
                            text: "You're requesting a visit directly with this vet. They'll confirm the slot and the price is settled from the service catalogue at the visit.",
                            systemImage: "info.circle.fill"
                        )
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
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    if viewModel.hasHoldExpired {
                        SlotHoldExpiredBanner { Task { await viewModel.extendHold() } }
                    } else if let seconds = viewModel.holdSecondsRemaining {
                        SlotHoldBanner(secondsRemaining: seconds)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                        if viewModel.canRetryPayment {
                            PrimaryButton(title: "Retry payment", isLoading: viewModel.isLoading) {
                                Task { await viewModel.retryCheckout() }
                            }
                        }
                    }
                    }
                    .transition(.bookingStep(isAdvancing: isAdvancing))
                }
            }
            .padding(16)
            // Room for the pinned action bar, so the last card is never
            // stranded underneath it.
            .padding(.bottom, 108)
        }
        .scrollContentBackground(.hidden)
        // A vertical-axis TextField has no Return key to dismiss with -
        // Return inserts a newline - and the app has no keyboard toolbar, so
        // without this a keyboard opened here covers the pinned action bar
        // with no way to put it away.
        .scrollDismissesKeyboard(.interactively)
        .floatingTabBarInset()
        .auroraScreenBackground()
        .safeAreaInset(edge: .bottom) {
            // The primary action is pinned rather than living at the end of a
            // long scroll: on a screen where the customer is deciding, the
            // commit step should never require hunting for it.
            confirmBar
        }
        .hidesFloatingTabBar()
        .navigationTitle("Book visit")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Whatever they already typed into the symptom check, so the same
            // question isn't asked twice. One-shot: consuming clears it.
            if viewModel.reason.isEmpty, let carried = bookingDraft.consumeReason() {
                viewModel.reason = carried
            }
            if let user = session.currentUser {
                await viewModel.loadPets(user: user)
                hasAcceptedWaiver = (try? await manageConsentUseCase.hasAcceptedLiabilityWaiver(userId: user.id)) ?? false
            }
        }
        .navigationDestination(item: $viewModel.bookedVisit) { visit in
            BookingConfirmedView(visit: visit) {
                viewModel.bookedVisit = nil
                dismiss()
            }
        }
        .overlay {
            if viewModel.isResolvingPayment {
                PaymentResolvingOverlay()
            }
        }
        .animation(Theme.crossFade, value: viewModel.isResolvingPayment)
        .animation(Theme.crossFade, value: viewModel.holdSecondsRemaining)
        .onDisappear {
            if viewModel.bookedVisit == nil { viewModel.releaseHold() }
        }
        // One sheet slot, not three stacked `.sheet` modifiers.
        //
        // The end-to-end booking test started failing when the add-address
        // sheet was added here, between checkout and the waiver. I have not
        // proven that stacking is the cause - SwiftUI does support it, and
        // VisitDetailView ships six - but three mutually exclusive sheets on
        // one screen is better expressed as one slot regardless: it cannot
        // race, cannot present two at once, and makes the state a single
        // value you can read. The test will say whether it was the cause.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .checkout(let url):
                CheckoutWebView(url: url)
            case .addAddress:
                if let user = session.currentUser {
                    // AddAddressView brings its own NavigationStack.
                    AddAddressView(ownerId: user.id) {
                        Task { await viewModel.reloadAddresses() }
                    }
                }
            case .waiver:
                if let user = session.currentUser {
                    LiabilityWaiverView(userId: user.id) {
                        hasAcceptedWaiver = true
                        Task { await viewModel.confirmBooking() }
                    }
                }
            }
        }
        // The view model owns the checkout URL, so mirror it into the one
        // sheet slot rather than giving it a competing modifier.
        .onChange(of: viewModel.checkoutURL) { _, url in
            if let url { activeSheet = .checkout(url) }
        }
        // Only the checkout sheet has work to do when it closes: it covers
        // the customer finishing payment, the payment failing, or them just
        // backing out, and all three have to be resolved against the server.
        .onChange(of: activeSheet) { previous, current in
            guard current == nil, case .checkout = previous else { return }
            viewModel.checkoutURL = nil
            Task { await viewModel.resolveCheckout() }
        }
    }

    /// Which single sheet this screen is showing.
    private enum BookingSheet: Identifiable, Equatable {
        case checkout(URL)
        case addAddress
        case waiver

        var id: String {
            switch self {
            case .checkout(let url): return "checkout-\(url.absoluteString)"
            case .addAddress: return "add-address"
            case .waiver: return "waiver"
            }
        }
    }



    // MARK: - Slot picker (F1/F2)

    /// Slots grouped by day, with the times for each day as a wrapping row of
    /// chips. The previous version listed every slot as a full-width row, so a
    /// vet running three stops a day for a week produced a 20-row wall the
    /// customer had to read linearly to find "Saturday morning".
    private var slotPicker: some View {
        let available = viewModel.circuit.schedule.filter(\.isAvailable).sorted { $0.startTime < $1.startTime }
        let byDay = Dictionary(grouping: available) { Calendar.current.startOfDay(for: $0.startTime) }
        let days = byDay.keys.sorted()

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Pick a time",
                subtitle: available.isEmpty ? nil : "\(available.count) slot\(available.count == 1 ? "" : "s") open",
                systemImage: "clock.fill"
            )

            if available.isEmpty {
                CalloutNote(
                    text: "This circuit has no open slots left. Try another vet in your area, or check back — schedules are published a week ahead.",
                    systemImage: "calendar.badge.exclamationmark", tint: Theme.warning
                )
            } else {
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dayLabel(day)).brandEyebrow()
                        FlowRow(spacing: 8) {
                            ForEach(byDay[day] ?? []) { slot in
                                SlotChip(
                                    slot: slot,
                                    isSelected: viewModel.selectedSlot?.id == slot.id
                                ) {
                                    viewModel.selectedSlot = slot
                                }
                            }
                        }
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 18)
                }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func petIcon(_ pet: Pet) -> String {
        switch pet.species {
        case .dog: return "dog.fill"
        case .cat: return "cat.fill"
        case .bird: return "bird.fill"
        case .other: return "pawprint.fill"
        }
    }

    private func petSubtitle(_ pet: Pet) -> String {
        var parts = [pet.species.rawValue.capitalized]
        if let breed = pet.breed, !breed.isEmpty { parts.append(breed) }
        if let weight = pet.weightKg { parts.append(String(format: "%.1f kg", weight)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Price (E3)

    /// E3: "transparent price breakdown" — every line the quote contains,
    /// including negative ones, above a total. Shown before the customer
    /// commits, not inside the checkout sheet afterwards.
    @ViewBuilder
    private var priceBreakdown: some View {
        if viewModel.isPricing && viewModel.previewQuote == nil {
            ShimmerView(cornerRadius: 18).frame(height: 120)
        } else if let quote = viewModel.previewQuote {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "What you'll pay", systemImage: "indianrupeesign.circle.fill")
                VStack(spacing: 10) {
                    ForEach(quote.breakdown.lineItems) { item in
                        InfoRow(
                            label: item.label,
                            value: (item.amountMinorUnits < 0 ? "−" : "") + CurrencyFormatter.rupees(abs(item.amountMinorUnits)),
                            valueColor: item.amountMinorUnits < 0 ? Theme.success : nil,
                            isMonospaced: true
                        )
                    }
                    GlassSeam()
                    HStack {
                        Text("Total").font(.brandHeadline)
                        Spacer()
                        Text(CurrencyFormatter.rupees(quote.breakdown.totalMinorUnits))
                            .font(.brandMono(.title3, weight: .bold))
                            .brandDisplayText()
                    }
                    Text("Price is locked for 10 minutes and re-checked against the server when you confirm — it can't change between here and payment.")
                        .font(.brandCaption2)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .featuredGlassCard()
            }
        }
    }

    // MARK: - Pinned action bar

    /// The pinned action bar. One primary action, whose label says what the
    /// tap will actually do at this step — "Continue" while choosing,
    /// "Confirm booking" only when that is genuinely what happens next.
    ///
    /// The total appears here only on the last step. Earlier it would either
    /// be a placeholder or a number that changes under the customer as they
    /// pick, and a price that moves while you are not looking at it is worse
    /// than no price.
    private var confirmBar: some View {
        VStack(spacing: 10) {
            if step == .confirm, let quote = viewModel.previewQuote {
                HStack {
                    Text("Total").font(.brandCaption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(CurrencyFormatter.rupees(quote.breakdown.totalMinorUnits))
                        .font(.brandMono(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                }
            }

            HStack(spacing: 10) {
                if flowPlan.previous(before: step) != nil {
                    Button {
                        goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .scaledIcon(16, weight: .semibold)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 52, height: 54)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.94))
                    .glassPanel(cornerRadius: 16, level: .chrome)
                    .accessibilityLabel("Back")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                PrimaryButton(
                    title: step == .confirm ? confirmTitle : step.advanceTitle,
                    systemImage: step == .confirm
                        ? (viewModel.canCheckoutWithPayment && !viewModel.payAfterVisit ? "lock.fill" : "checkmark")
                        : nil,
                    isLoading: viewModel.isLoading,
                    isEnabled: canAdvance
                ) {
                    advance()
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.9), value: step)

            // Says what is missing, at the step where it is missing — rather
            // than one generic hint that was wrong on two screens out of three.
            if !canAdvance {
                Text(blockingHint)
                    .font(.brandCaption2)
                    .foregroundStyle(Theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // iOS 26 guidance is to differentiate controls from content with
        // the material rather than a solid or semi-opaque strip beneath
        // them, and to let content scroll under it. `.bar` was the old
        // answer; glass is the current one.
        .glassEffect(.regular, in: Rectangle())
    }

    /// Where the vet should come. On the confirm step, because it belongs
    /// beside the other things being agreed to - not as a fourth step that
    /// makes a three-tap booking a four-tap one.
    @ViewBuilder
    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Where should the vet come?", systemImage: "house.fill")

            if viewModel.addresses.isEmpty {
                CalloutNote(
                    text: "You haven't saved an address yet. Add one so the vet knows where to go — you can still book now and we'll confirm the address with you.",
                    systemImage: "mappin.slash", tint: Theme.warning
                )
                Button {
                    Haptics.tap()
                    activeSheet = .addAddress
                } label: {
                    Label("Add an address", systemImage: "plus")
                        .font(.brandCallout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(Theme.primary)
            } else {
                ForEach(viewModel.addresses) { address in
                    SelectableRow(
                        title: address.label,
                        subtitle: addressSubtitle(address),
                        systemImage: address.isServed ? "mappin.circle.fill" : "exclamationmark.triangle.fill",
                        isSelected: viewModel.selectedAddress?.id == address.id
                    ) {
                        viewModel.selectedAddress = address
                    }
                }

                // A saved address outside every served cluster is the one
                // case where picking it and tapping Confirm would look fine
                // and then strand somebody, so it is said here rather than
                // discovered afterwards.
                if let selected = viewModel.selectedAddress, !selected.isServed {
                    CalloutNote(
                        text: "We don't cover \(selected.label) yet. You can still book — the vet will call to work out whether they can reach you.",
                        systemImage: "exclamationmark.triangle.fill", tint: Theme.warning
                    )
                }
            }
        }
    }

    /// Optional on purpose. Making this required would hold a booking hostage
    /// to somebody's ability to describe a symptom, which is the opposite of
    /// what you want from a worried owner at 11pm - and the vet is going to
    /// ask anyway. It is here because arriving with nothing at all is worse.
    @ViewBuilder
    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "What's going on?",
                subtitle: "Optional — it helps the vet come prepared",
                systemImage: "text.bubble.fill"
            )

            TextField(
                "e.g. not eating since yesterday, limping on a back leg",
                text: $viewModel.reason,
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(.brandCallout)
            .textInputAutocapitalization(.sentences)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func addressSubtitle(_ address: Address) -> String {
        var parts = [address.line1]
        if let landmark = address.landmark, !landmark.isEmpty { parts.append("near \(landmark)") }
        return parts.joined(separator: " · ")
    }

    private var blockingHint: String {
        switch step {
        case .slot: return "Pick a time to continue"
        case .pet: return "Choose which pet this visit is for"
        case .confirm: return "Something's missing — go back and check your time and pet"
        }
    }

    private var confirmTitle: String {
        // The first tap on a never-before-signed account opens the liability
        // waiver, not payment. Promising "Confirm & pay securely" and then
        // showing a consent form reads as a bait and switch at exactly the
        // moment the customer is deciding whether to trust us with money.
        guard hasAcceptedWaiver else { return "Review & continue" }
        guard viewModel.canCheckoutWithPayment else { return "Request this visit" }
        return viewModel.payAfterVisit ? "Confirm — pay after visit" : "Confirm & pay securely"
    }
}

/// A wrapping row: lays children out left to right and moves to a new line
/// when the next one won't fit. `LazyVGrid` can't do this — its columns are
/// fixed, so a row of time chips of different widths either overflows or
/// leaves ragged gaps.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One bookable time. 44pt tall so it is a real target, and it says how much
/// room is left (F2) rather than just the time.
private struct SlotChip: View {
    let slot: ScheduleSlot
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 1) {
                Text(slot.startTime.formatted(date: .omitted, time: .shortened))
                    .font(.brandMono(.subheadline, weight: .semibold))
                if slot.remainingCapacity <= 2 {
                    Text("\(slot.remainingCapacity) left")
                        // Was 9pt and fixed. Nothing in the system type
                        // scale is that small, it never grew with Dynamic
                        // Type, and "2 left" is scarcity a person decides on
                        // — not fine print.
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.warning)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(isSelected ? .white : .primary)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.10), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.93))
        .animation(Theme.springQuick, value: isSelected)
        .accessibilityLabel("\(slot.startTime.formatted(date: .abbreviated, time: .shortened)), \(slot.remainingCapacity) spot\(slot.remainingCapacity == 1 ? "" : "s") left")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The shared "pick one of these" row used for pets and payment method. The
/// whole row is the Button's label, so the full width is tappable rather than
/// just the text — the selected state comes from the app-wide
/// `selectable(isSelected:)` treatment so every picker looks the same.
private struct SelectableRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(Theme.springQuick) { action() }
        } label: {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .scaledIcon(16, weight: .medium)
                        .foregroundStyle(isSelected ? Color.white : Theme.primary)
                        .frame(width: 38, height: 38)
                        .background {
                            Circle()
                                .fill(isSelected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.primary.opacity(0.12)))
                                .allowsHitTesting(false)
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.brandHeadline).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.brandCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(minHeight: 44)
            .glassCard(cornerRadius: 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .selectable(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct BookingConfirmedView: View {
    let visit: Visit

    /// Clears the booking that pushed this screen, popping the flow. The
    /// screen hides the back button - correctly, since the booking is already
    /// placed and "back to the payment step" is meaningless - so without this
    /// there is no way off it at all except force-quitting the app.
    var onDone: () -> Void = {}

    @Environment(Router.self) private var router
    @State private var checkmarkScale: CGFloat = 0.4
    @State private var ringOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.4)
            ConfettiView().allowsHitTesting(false)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Theme.success.opacity(0.3), lineWidth: 8)
                        .frame(width: 96, height: 96)
                        .scaleEffect(ringOpacity == 0 ? 0.6 : 1.3)
                        .opacity(1 - ringOpacity)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(Theme.success)
                        .scaleEffect(checkmarkScale)
                        .shadow(color: Theme.success.opacity(0.5), radius: 16, y: 6)
                }
                .allowsHitTesting(false)
                .onAppear {
                    guard !reduceMotion else {
                        checkmarkScale = 1
                        ringOpacity = 1
                        return
                    }
                    // Bounce is earned here: this is the rare celebratory
                    // moment, not a control the user fires all day.
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { checkmarkScale = 1 }
                    withAnimation(.easeOut(duration: 0.9).delay(0.1)) { ringOpacity = 1 }
                }

                VStack(spacing: 8) {
                    Text("Booking requested").font(.brandLargeTitle).brandDisplayText()
                    Text("We'll notify you the moment a vet confirms your slot — usually within a few minutes.")
                        .font(.brandCallout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                StatusBadge(status: visit.status)

                VStack(spacing: 10) {
                    InfoRow(
                        label: "When", value: visit.scheduledAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar"
                    )
                    // E10: the receipt notification was just sent — surfaced
                    // here so it isn't a silent side effect.
                    InfoRow(label: "Confirmation", value: "Sent to your phone", systemImage: "bell.badge")
                }
                .padding(16)
                .glassCard()

                CalloutNote(
                    text: "You can track the vet live, message them, and cancel from the Visits tab. Cancelling more than \(Int(CancellationPolicy.freeWindowHours))h ahead is free.",
                    systemImage: "info.circle.fill"
                )

                VStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        // Switches to Visits and pushes this visit's detail,
                        // so the obvious next question - "where is it?" - is
                        // one tap away rather than a hunt through a tab.
                        router.handle(.visit(visit.id))
                        onDone()
                    } label: {
                        Text("Track this visit")
                            .font(.brandHeadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)

                    Button {
                        Haptics.tap()
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.brandCallout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .appearAnimation()
        }
        .navigationBarBackButtonHidden()
        .interactiveDismissDisabled()
    }
}

#Preview {
    NavigationStack {
        BookingView(circuit: MockData.circuits[0])
            .environment(SessionStore())
            .environment(Router())
            .environment(BookingDraft())
    }
}
