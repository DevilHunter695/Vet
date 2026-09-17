import SwiftUI

/// L3: shared verified-badge treatment — a vet either shows this clearly or,
/// per plan §L1, shouldn't be visible in the booking flow at all (see
/// `MockCircuitRepository.listCircuits`, which now filters unverified vets
/// out before this badge would even matter).
struct VerifiedBadge: View {
    let status: Vet.VerificationStatus

    var body: some View {
        switch status {
        case .verified:
            TagChip(text: "VCI Verified", systemImage: "checkmark.seal.fill", tint: Theme.primaryLight)
        case .pending:
            TagChip(text: "Verification pending", systemImage: "clock.badge.exclamationmark", tint: Theme.warning)
        case .rejected:
            TagChip(text: "Not verified", systemImage: "xmark.seal.fill", tint: Theme.danger)
        }
    }
}

@Observable
@MainActor
final class VetDetailViewModel {
    var reviews: [Review] = []
    var isLoading = false

    private let getVetProfileUseCase = DependencyContainer.shared.getVetProfileUseCase()

    var histogram: GetVetProfileUseCase.RatingsHistogram {
        getVetProfileUseCase.histogram(for: reviews)
    }

    func load(vetId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        reviews = (try? await getVetProfileUseCase.reviews(vetId: vetId)) ?? []
    }
}

/// C5: the vet detail screen — photo, bio, VCI reg no., verified badge,
/// years of experience, species, languages, services/prices are all read
/// straight off `Vet`; ratings histogram and reviews are computed here from
/// `ReviewRepository.reviews(vetId:)`; next-7-days availability comes from
/// the circuit's own schedule slots (passed in, since a `Vet` alone doesn't
/// carry a schedule).
struct VetDetailView: View {
    let vet: Vet
    var clusterArea: String? = nil
    var upcomingSlots: [ScheduleSlot] = []

    @State private var viewModel = VetDetailViewModel()

    private var nextSevenDaysSlots: [ScheduleSlot] {
        let cutoff = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        return upcomingSlots.filter { $0.isAvailable && $0.startTime <= cutoff }.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if vet.verificationStatus != .verified {
                    // L1/L3: shown for completeness (e.g. if this view is
                    // reached from an ops/preview context) — the customer
                    // discovery path itself never surfaces an unverified vet.
                    ErrorBanner(message: "This vet hasn't completed verification yet and can't be booked.")
                }
                if let bio = vet.bio {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("About", systemImage: "person.text.rectangle")
                                .font(.brandHeadline).foregroundStyle(Theme.primary)
                            Text(bio).font(.brandBody)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                factsGrid
                // C5 "services + prices": vets don't carry their own catalog
                // in this model (services are shared across the marketplace,
                // priced identically by any vet) — link out to the same
                // catalog screen rather than duplicating prices here.
                NavigationLink {
                    ServiceCatalogView(vertical: .vet, pet: MockData.user.pets.first)
                } label: {
                    Label("View services & prices", systemImage: "list.bullet.rectangle")
                        .font(.brandHeadline)
                }
                .buttonStyle(PressableStyle())
                if !nextSevenDaysSlots.isEmpty {
                    availabilitySection
                }
                if viewModel.histogram.totalCount > 0 {
                    ratingsSection
                }
                if !viewModel.reviews.isEmpty {
                    reviewsSection
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle(vet.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(vetId: vet.id) }
    }

    /// Luma's image-led header: the vet's own photograph is both the poster
    /// and, blurred behind it, the colour of the screen. A stethoscope glyph
    /// on a brand circle told the customer nothing about the person they are
    /// about to let into their home — and this is the last screen before they
    /// decide to.
    private var header: some View {
        PosterHeader(
            imageURL: vet.photoURL,
            fallbackSymbol: "stethoscope",
            seed: vet.id.uuidString,
            title: vet.name,
            subtitle: clusterArea
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label {
                        Text(String(format: "%.1f", vet.rating))
                            .font(.brandMono(.callout, weight: .bold))
                    } icon: {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Theme.goldTier)
                    }

                    Text("(\(vet.reviewCount) review\(vet.reviewCount == 1 ? "" : "s"))")
                        .font(.brandCaption)
                        .foregroundStyle(Theme.textSecondary)

                    if let years = vet.yearsOfExperience {
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text("\(years) yr\(years == 1 ? "" : "s") experience")
                            .font(.brandCaption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                VerifiedBadge(status: vet.verificationStatus)
            }
            .padding(.top, 2)
        }
        .appearAnimation()
    }

    private var factsGrid: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                FactRow(icon: "number", title: "VCI reg. no.", value: vet.licenseNumber)
                if let years = vet.yearsOfExperience {
                    FactRow(icon: "calendar.badge.clock", title: "Experience", value: "\(years) year\(years == 1 ? "" : "s")")
                }
                if !vet.speciesHandled.isEmpty {
                    FactRow(icon: "pawprint", title: "Species handled",
                            value: vet.speciesHandled.map { $0.rawValue.capitalized }.joined(separator: ", "))
                }
                if !vet.languages.isEmpty {
                    FactRow(icon: "globe", title: "Languages", value: vet.languages.joined(separator: ", "))
                }
                if let gender = vet.gender {
                    FactRow(icon: "person", title: "Gender", value: gender.displayName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appearAnimation(delay: 0.05)
    }

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next 7 days").font(.brandHeadline)
            ForEach(nextSevenDaysSlots.prefix(10)) { slot in
                HStack {
                    Text(slot.startTime.formatted(date: .abbreviated, time: .shortened)).font(.brandBody)
                    Spacer()
                    Text("\(slot.remainingCapacity) spot\(slot.remainingCapacity == 1 ? "" : "s") left")
                        .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .appearAnimation(delay: 0.1)
    }

    private var ratingsSection: some View {
        let histogram = viewModel.histogram
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ratings").font(.brandHeadline)
                ForEach((1...5).reversed(), id: \.self) { stars in
                    let count = histogram.countByStars[stars] ?? 0
                    let fraction = histogram.totalCount == 0 ? 0 : Double(count) / Double(histogram.totalCount)
                    HStack(spacing: 8) {
                        Text("\(stars)").font(.caption).monospacedDigit().frame(width: 12)
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.goldTier)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.systemGray5))
                                Capsule().fill(Theme.primary).frame(width: geo.size.width * fraction)
                            }
                        }
                        .frame(height: 8)
                        Text("\(count)").font(.caption2).foregroundStyle(Theme.textSecondary).frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appearAnimation(delay: 0.15)
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reviews").font(.brandHeadline)
            ForEach(viewModel.reviews.prefix(20)) { review in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: index < review.rating ? "star.fill" : "star")
                                .font(.caption2).foregroundStyle(Theme.goldTier)
                        }
                    }
                    if let comment = review.comment {
                        Text(comment).font(.brandBody)
                    }
                    Text(review.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .appearAnimation(delay: 0.2)
    }
}

private struct FactRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.primary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
                Text(value).font(.brandBody)
            }
        }
    }
}

#Preview {
    NavigationStack {
        VetDetailView(vet: MockData.vets[0], clusterArea: "Koramangala 5th Block",
                      upcomingSlots: MockData.circuits[0].schedule)
    }
}
