import Foundation
import Testing
@testable import VetCircuit

// MARK: - N7: Router's pure routing logic.
//
// `Router.handle(_:)` is a deterministic mapping from a `DeepLink` to
// (selectedTab, pushed Route) — the deep-link parsing itself is covered by
// `DeepLinkParserTests` in HouseholdSearchWaitlistTests.swift. Actual
// on-screen navigation (whether `.navigationDestination` renders the right
// view for a given Route) isn't covered here; that's a UI concern Swift
// Testing can't meaningfully assert on.
@Suite("Router.handle")
@MainActor
struct RouterHandleTests {
    @Test("a .visit deep link switches to the Visits tab and pushes .visitDetail")
    func visitDeepLinkPushesVisitDetail() {
        let router = Router()
        let id = UUID()
        router.handle(.visit(id))
        #expect(router.selectedTab == Router.Tab.visits.rawValue)
        #expect(router.visitsPath.count == 1)
    }

    @Test("a .chat deep link switches to the Visits tab and pushes .chat — the destination plan §6.1 called out as unreachable")
    func chatDeepLinkPushesChat() {
        let router = Router()
        let visitId = UUID()
        router.handle(.chat(visitId: visitId))
        #expect(router.selectedTab == Router.Tab.visits.rawValue)
        #expect(router.visitsPath.count == 1)
        // profilePath is untouched by a Visits-tab route.
        #expect(router.profilePath.count == 0)
    }

    @Test("a .household deep link switches to the Profile tab and pushes .household")
    func householdDeepLinkPushesHousehold() {
        let router = Router()
        router.handle(.household)
        #expect(router.selectedTab == Router.Tab.profile.rawValue)
        #expect(router.profilePath.count == 1)
        #expect(router.visitsPath.count == 0)
    }

    @Test("a .book deep link changes neither tab nor any path — CircuitsListView resolves it itself")
    func bookDeepLinkIsANoOp() {
        let router = Router()
        let startingTab = router.selectedTab
        router.handle(.book(circuitId: UUID()))
        #expect(router.selectedTab == startingTab)
        #expect(router.visitsPath.count == 0)
        #expect(router.profilePath.count == 0)
    }

    @Test("an .unknown deep link changes nothing")
    func unknownDeepLinkIsANoOp() {
        let router = Router()
        let startingTab = router.selectedTab
        router.handle(.unknown)
        #expect(router.selectedTab == startingTab)
        #expect(router.visitsPath.count == 0)
        #expect(router.profilePath.count == 0)
    }

    @Test("a second deep link to the same tab resets the path rather than piling on")
    func secondDeepLinkResetsPath() {
        let router = Router()
        router.handle(.visit(UUID()))
        #expect(router.visitsPath.count == 1)
        router.handle(.chat(visitId: UUID()))
        #expect(router.visitsPath.count == 1)
    }
}
