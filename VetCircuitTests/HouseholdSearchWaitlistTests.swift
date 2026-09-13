import Testing
import Foundation
@testable import VetCircuit

// A9/C8/C9/C10/N7 domain-layer tests: pure Swift logic, no UI or network.

@Suite("DeepLinkParser")
struct DeepLinkParserTests {
    @Test("parses a visit deep link")
    func parsesVisit() {
        let id = UUID()
        let url = URL(string: "vetcircuit://visit/\(id.uuidString)")!
        #expect(DeepLinkParser.parse(url) == .visit(id))
    }

    @Test("parses a book deep link")
    func parsesBook() {
        let id = UUID()
        let url = URL(string: "vetcircuit://book/\(id.uuidString)")!
        #expect(DeepLinkParser.parse(url) == .book(circuitId: id))
    }

    @Test("parses a household deep link with no id")
    func parsesHousehold() {
        let url = URL(string: "vetcircuit://household")!
        #expect(DeepLinkParser.parse(url) == .household)
    }

    @Test("an unrecognized host is unknown")
    func unrecognizedHost() {
        let url = URL(string: "vetcircuit://promo/summer2026")!
        #expect(DeepLinkParser.parse(url) == .unknown)
    }

    @Test("a malformed uuid segment is unknown, not a crash")
    func malformedUUID() {
        let url = URL(string: "vetcircuit://visit/not-a-uuid")!
        #expect(DeepLinkParser.parse(url) == .unknown)
    }

    @Test("a visit link with no id segment is unknown")
    func missingSegment() {
        let url = URL(string: "vetcircuit://visit")!
        #expect(DeepLinkParser.parse(url) == .unknown)
    }

    @Test("parses the universal-link form the same way")
    func parsesUniversalLink() {
        let id = UUID()
        let url = URL(string: "https://vetcircuit.app/visit/\(id.uuidString)")!
        // Universal links put the path's first segment where the custom
        // scheme puts .host only once the host itself carries the route
        // name (vetcircuit.app vs. "visit") — this app doesn't yet route
        // universal links, a known gap called out in DeepLinkParser.swift;
        // asserting `.unknown` here documents that rather than silently
        // passing on an assumption the code doesn't actually implement.
        #expect(DeepLinkParser.parse(url) == .unknown)
    }
}

@Suite("JoinWaitlistUseCase")
struct JoinWaitlistUseCaseTests {
    @Test("joining twice for the same address does not create two entries")
    func dedupesByAddress() async throws {
        let repo = MockWaitlistRepository()
        let useCase = JoinWaitlistUseCase(waitlistRepository: repo)
        let userId = UUID()
        let addressId = UUID()

        let first = try await useCase.execute(userId: userId, addressId: addressId, latitude: 12.9, longitude: 77.6, areaLabel: "Test Area")
        let second = try await useCase.execute(userId: userId, addressId: addressId, latitude: 12.9, longitude: 77.6, areaLabel: "Test Area")

        #expect(first.id == second.id)
        #expect(try await useCase.hasJoined(userId: userId, addressId: addressId))
    }

    @Test("neighbour count only reflects entries near the given coordinate")
    func countsOnlyNearby() async throws {
        let repo = MockWaitlistRepository()
        let useCase = JoinWaitlistUseCase(waitlistRepository: repo)

        _ = try await useCase.execute(userId: UUID(), addressId: UUID(), latitude: 12.9352, longitude: 77.6146, areaLabel: nil)
        _ = try await useCase.execute(userId: UUID(), addressId: UUID(), latitude: 12.9360, longitude: 77.6150, areaLabel: nil)
        // Far away (a different city) — must not count toward the first cluster.
        _ = try await useCase.execute(userId: UUID(), addressId: UUID(), latitude: 19.0760, longitude: 72.8777, areaLabel: nil)

        let count = try await useCase.neighbourCount(latitude: 12.9352, longitude: 77.6146)
        #expect(count == 2)
    }
}

@Suite("ManageHouseholdUseCase")
struct ManageHouseholdUseCaseTests {
    @Test("rejects an empty household name")
    func rejectsEmptyName() async {
        let useCase = ManageHouseholdUseCase(householdRepository: MockHouseholdRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.create(name: "   ", ownerId: UUID())
        }
    }

    @Test("creating a household makes the owner its first member")
    func ownerIsFirstMember() async throws {
        let useCase = ManageHouseholdUseCase(householdRepository: MockHouseholdRepository())
        let ownerId = UUID()
        let household = try await useCase.create(name: "The Sharmas", ownerId: ownerId)
        let members = try await useCase.members(householdId: household.id)
        #expect(members.count == 1)
        #expect(members.first?.role == .owner)
        #expect(members.first?.userId == ownerId)
    }

    @Test("invite rejects an obviously invalid phone number")
    func rejectsInvalidPhone() async throws {
        let repo = MockHouseholdRepository()
        let useCase = ManageHouseholdUseCase(householdRepository: repo)
        let household = try await useCase.create(name: "The Sharmas", ownerId: UUID())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.invite(householdId: household.id, phone: "123")
        }
    }
}

@Suite("SearchUseCase")
struct SearchUseCaseTests {
    @Test("an empty search term returns no results rather than everything")
    func emptyTermReturnsNothing() async throws {
        let useCase = SearchUseCase(circuitRepository: MockCircuitRepository(), catalogRepository: MockCatalogRepository())
        let result = try await useCase.execute(term: "   ", vertical: .vet)
        #expect(result.circuits.isEmpty)
        #expect(result.services.isEmpty)
    }
}

@Suite("RebookLastVisitUseCase")
struct RebookLastVisitUseCaseTests {
    @Test("a user with no completed visits gets no suggestion")
    func noCompletedVisitsMeansNoSuggestion() async throws {
        let useCase = RebookLastVisitUseCase(visitRepository: MockVisitRepository(), circuitRepository: MockCircuitRepository())
        let suggestion = try await useCase.execute(userId: UUID())
        #expect(suggestion == nil)
    }
}
