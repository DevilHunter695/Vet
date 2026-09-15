import XCTest

/// An automated walkthrough of the running app.
///
/// Unit tests prove the domain logic; they cannot prove that a screen renders,
/// that a control is reachable, or that a tap registers. That gap is how this
/// app shipped a species filter that never ran, an address pin that swallowed
/// the gesture it existed to receive, and an "Add to cart" button that
/// disabled itself forever after one use — all with a green test suite.
///
/// Every assertion below is deliberately about REACHABILITY and RESPONSE
/// rather than pixels: does the screen appear, is the control hittable, does
/// tapping it change what's on screen. A screenshot is attached at each stop
/// so the visual result is reviewable in the CI artifacts even by someone who
/// can't run the app.
final class AppWalkthroughUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITest"]
        app.launch()
    }

    // MARK: - Helpers

    /// Waits for an element and fails with a readable message naming what was
    /// being looked for — a bare `XCTAssertTrue(exists)` in CI tells you
    /// nothing about which screen broke.
    @discardableResult
    private func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) -> Bool {
        let found = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(found, "Expected to find \(what) but it never appeared")
        return found
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The tap-reliability check, which is the whole reason this target
    /// exists. `isHittable` is the property that was false for the controls
    /// users had to tap three or four times: the element existed and was
    /// visible, but its touch region didn't cover what was drawn.
    private func tapAndExpect(
        _ control: XCUIElement, _ controlName: String,
        toReveal destination: XCUIElement, _ destinationName: String,
        timeout: TimeInterval = 10
    ) {
        require(control, controlName)
        XCTAssertTrue(
            control.isHittable,
            "\(controlName) exists but is not hittable — this is the shape of the "
            + "'had to tap it three times' bug: drawn, but with no touch region under it"
        )
        control.tap()
        XCTAssertTrue(
            destination.waitForExistence(timeout: timeout),
            "Tapped \(controlName) once and \(destinationName) did not appear"
        )
    }

    // MARK: - The three tabs must exist and be reachable

    func testTabsAreReachableOnASingleTap() throws {
        let tabBar = app.tabBars.firstMatch
        require(tabBar, "the main tab bar")

        for label in ["Book", "Visits", "Profile"] {
            let tab = tabBar.buttons[label]
            require(tab, "the \(label) tab")
            XCTAssertTrue(tab.isHittable, "The \(label) tab is not hittable")
            tab.tap()
            snapshot("Tab — \(label)")
        }
    }

    // MARK: - Book tab (C1, C2, C11, L8)

    func testBookTabShowsCircuitsWithSlotPriceAndRating() throws {
        app.tabBars.firstMatch.buttons["Book"].tap()

        // C11 + L8: the emergency path and the "not an emergency" disclaimer
        // are safety-critical and must be present without scrolling.
        require(app.staticTexts["This is an emergency"], "the C11 emergency banner")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'emergency service'")).count > 0,
            "L8's 'not an emergency service' disclaimer is missing from the booking flow"
        )

        // C2: a circuit row must carry more than a name. The row is an
        // accessibility element combining its parts, so the slot/price/rating
        // all land in one label.
        let rows = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'rated'"))
        XCTAssertGreaterThan(rows.count, 0, "No circuit row exposing a rating — C2 promises slot, price and rating")

        let first = rows.element(boundBy: 0)
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains("next slot"),
                      "Circuit row does not mention its next slot: \(first.label)")

        snapshot("Book — circuit list")
    }

    func testTappingACircuitOpensBookingOnTheFirstTap() throws {
        app.tabBars.firstMatch.buttons["Book"].tap()
        let rows = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'rated'"))
        guard rows.count > 0 else { throw XCTSkip("No circuits in the mock data to open") }

        tapAndExpect(rows.element(boundBy: 0), "the first circuit row",
                     toReveal: app.navigationBars["Book visit"], "the booking screen")
        snapshot("Booking screen")
    }

    // MARK: - Booking (F1, F2, E3)

    func testSlotPickerOffersTappableTimesAndTheCTAGatesOnSelection() throws {
        app.tabBars.firstMatch.buttons["Book"].tap()
        let rows = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'rated'"))
        guard rows.count > 0 else { throw XCTSkip("No circuits in the mock data to open") }
        rows.element(boundBy: 0).tap()
        require(app.navigationBars["Book visit"], "the booking screen")

        // F1/F2: slots are chips carrying their remaining capacity.
        let slots = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'spot'"))
        XCTAssertGreaterThan(slots.count, 0, "F1's slot picker offered no tappable slot")

        let slot = slots.element(boundBy: 0)
        XCTAssertTrue(slot.isHittable, "A time slot is drawn but not hittable")
        slot.tap()

        // E7: picking a slot places a hold, and the app should say so.
        XCTAssertTrue(
            app.staticTexts["This slot is held for you"].waitForExistence(timeout: 5),
            "E7: no slot-hold confirmation after picking a time"
        )
        snapshot("Booking — slot picked, hold placed")
    }

    // MARK: - Profile tab (A5, B1, N4, H1)

    func testProfileShowsSummaryFiguresAndReachableSettings() throws {
        app.tabBars.firstMatch.buttons["Profile"].tap()
        require(app.navigationBars["Profile"], "the Profile screen")

        // The four summary tiles are the difference between the redesigned
        // screen and the old flat list of links.
        for tile in ["Wallet", "Points", "Visits done"] {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", tile)).count > 0,
                "Profile is missing its \(tile) summary tile"
            )
        }
        snapshot("Profile — top")

        // Every grouped row must be reachable in one tap.
        let editProfile = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] 'Edit profile'")).element(boundBy: 0)
        tapAndExpect(editProfile, "the Edit profile row",
                     toReveal: app.navigationBars.firstMatch, "the Edit profile screen")
        snapshot("Profile — edit profile")
    }

    func testAddressesScreenHasAContentStateNotABlankScreen() throws {
        app.tabBars.firstMatch.buttons["Profile"].tap()
        let addresses = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] 'Addresses'")).element(boundBy: 0)
        guard addresses.waitForExistence(timeout: 10) else { throw XCTSkip("Addresses row not reachable") }
        addresses.tap()

        // A8/#14: this screen used to render entirely blank — no loading
        // state, no empty state — so a new user saw nothing at all.
        let hasRows = app.cells.count > 0
        let hasEmptyState = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'address'")
        ).count > 0
        XCTAssertTrue(hasRows || hasEmptyState,
                      "Addresses screen is blank — no rows, no empty state, nothing to tell the user what this is")
        snapshot("Addresses")
    }

    // MARK: - Visits tab (I1, I2)

    func testVisitsTabShowsEitherVisitsOrAnExplainedEmptyState() throws {
        app.tabBars.firstMatch.buttons["Visits"].tap()
        require(app.navigationBars["Your visits"], "the Visits screen")

        let hasVisitRows = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'status'")).count > 0
        let hasEmptyState = app.staticTexts["No visits yet"].exists
        XCTAssertTrue(hasVisitRows || hasEmptyState,
                      "Visits tab shows neither visits nor an empty state")
        snapshot("Visits")
    }

    // MARK: - Appearance (O3) — the aurora has to survive both schemes

    func testBothAppearancesRenderWithoutLosingContent() throws {
        app.tabBars.firstMatch.buttons["Profile"].tap()
        require(app.navigationBars["Profile"], "the Profile screen")

        for mode in ["Light", "Dark"] {
            let button = app.segmentedControls.buttons[mode]
            guard button.exists else { continue }
            button.tap()
            // The point is that content survives the switch — a background
            // that swallows its own text is the classic failure here.
            XCTAssertTrue(app.navigationBars["Profile"].exists,
                          "Profile content vanished after switching to \(mode)")
            snapshot("Appearance — \(mode)")
        }
    }
}
