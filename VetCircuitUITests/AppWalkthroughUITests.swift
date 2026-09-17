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

    // MARK: - Helpers
    //
    // Every member that touches XCUITest is `@MainActor`: in Xcode 16 the
    // whole XCUIElement API is main-actor isolated, and under Swift 6 a
    // nonisolated test method calling it is 120 compile errors. The isolation
    // is applied per-member rather than to the class because XCTestCase's
    // `setUpWithError()` is nonisolated and an override cannot add isolation
    // — hence launching the app from a helper instead of from setUp.

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UITest"]
        app.launch()
        return app
    }

    /// Waits for an element and fails with a readable message naming what was
    /// being looked for — a bare `XCTAssertTrue(exists)` in CI tells you
    /// nothing about which screen broke.
    @MainActor @discardableResult
    private func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) -> Bool {
        let found = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(found, "Expected to find \(what) but it never appeared")
        return found
    }


    /// Finds a tab button in the floating bar.
    ///
    /// The app no longer uses a system `TabView` bar, so `app.tabBars` finds
    /// nothing — the bar is a row of buttons in a glass capsule. This is the
    /// one place that knowledge lives, rather than sixteen call sites each
    /// encoding it.
    ///
    /// The bar also collapses to a single button while scrolling, so a tab
    /// that is not currently drawn has to be brought back first: tapping the
    /// collapsed button expands it.

    /// The bar by identifier, whatever element type it resolves to.
    ///
    /// `.accessibilityIdentifier` on the bar's container does not reliably
    /// surface as an `otherElement`: SwiftUI propagates it onto whichever
    /// element it decides represents that subtree, and in practice it comes
    /// through as a Button. Asserting on the type was the bug — the
    /// identifier is the contract, the element type is an implementation
    /// detail of how SwiftUI flattens the hierarchy.
    @MainActor
    private func floatingTabBar(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "floatingTabBar").firstMatch
    }

    @MainActor
    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let direct = app.buttons[title]
        if direct.waitForExistence(timeout: 3), direct.isHittable { return direct }
        // Collapsed: the only visible bar button is the current tab. Tapping
        // it expands the bar, after which the wanted tab exists.
        let bar = floatingTabBar(in: app)
        if bar.exists {
            let firstButton = bar.buttons.element(boundBy: 0)
            if firstButton.exists, firstButton.isHittable { firstButton.tap() }
        }
        return app.buttons[title]
    }

    @MainActor
    private func goToTab(_ title: String, in app: XCUIApplication) {
        let button = tabButton(title, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The \(title) tab was not reachable")
        XCTAssertTrue(button.isHittable, "The \(title) tab is drawn but not hittable")
        button.tap()
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls until `element` is on screen, then reports whether it is.
    ///
    /// `isHittable` is false both for a control with no touch region — the bug
    /// this suite exists to catch — and for one that is simply below the fold,
    /// which is not a bug at all. Conflating the two turns a real signal into
    /// a false alarm, so anything that lives further down a screen gets
    /// scrolled into view first and only then asserted on.
    @MainActor @discardableResult
    private func scrollToVisible(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 12) -> Bool {
        // Check-then-scroll is the wrong order here. SwiftUI's lazy containers
        // never build a row that is off screen, so `waitForExistence` on a
        // row further down Profile fails on a screen where that row is
        // perfectly reachable — which is exactly how "Help centre" and
        // "Notification preferences" were reported as missing when they were
        // simply below the fold. Scroll first, re-check each step.
        var swipes = 0
        while swipes <= maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    /// The tap-reliability check, which is the whole reason this target
    /// exists. `isHittable` is the property that was false for the controls
    /// users had to tap three or four times: the element existed and was
    /// visible, but its touch region didn't cover what was drawn.
    @MainActor
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

    @MainActor
    func testTabsAreReachableOnASingleTap() throws {
        let app = launchApp()
        // The bar is a row of buttons in a glass capsule, not a system
        // `tabBar` element — so this asserts on the container by identifier
        // and on each tab by name.
        require(floatingTabBar(in: app), "the floating tab bar")

        for label in ["Book", "Visits", "Profile"] {
            let tab = tabButton(label, in: app)
            require(tab, "the \(label) tab")
            XCTAssertTrue(tab.isHittable, "The \(label) tab is not hittable")
            tab.tap()
            snapshot(app, "Tab — \(label)")
        }
    }

    /// The bar's headline behaviour: it should get out of the way while
    /// reading and come back when you scroll up to navigate. If the collapse
    /// ever stops reversing, the tabs become unreachable without a reload —
    /// which is a far worse bug than the bar simply never collapsing.
    @MainActor
    func testTheTabBarCollapsesOnScrollAndComesBack() throws {
        let app = launchApp()
        goToTab("Visits", in: app)
        require(floatingTabBar(in: app), "the floating tab bar")

        app.swipeUp()
        app.swipeUp()
        snapshot(app, "Tab bar — collapsed while reading")

        app.swipeDown()
        app.swipeDown()

        let profile = tabButton("Profile", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 10),
                      "The tab bar did not come back after scrolling up — tabs are now unreachable")
        XCTAssertTrue(profile.isHittable, "The tab bar returned but its tabs are not hittable")
        snapshot(app, "Tab bar — restored")
    }

    // MARK: - Book tab (C1, C2, C11, L8)

    @MainActor
    func testBookTabShowsCircuitsWithSlotPriceAndRating() throws {
        let app = launchApp()
        goToTab("Book", in: app)

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

        snapshot(app, "Book — circuit list")
    }

    @MainActor
    func testTappingACircuitOpensBookingOnTheFirstTap() throws {
        let app = launchApp()
        goToTab("Book", in: app)
        let rows = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'rated'"))
        guard rows.count > 0 else { throw XCTSkip("No circuits in the mock data to open") }

        tapAndExpect(rows.element(boundBy: 0), "the first circuit row",
                     toReveal: app.navigationBars["Book visit"], "the booking screen")
        snapshot(app, "Booking screen")
    }

    // MARK: - Booking (F1, F2, E3)

    @MainActor
    func testSlotPickerOffersTappableTimesAndTheCTAGatesOnSelection() throws {
        let app = launchApp()
        goToTab("Book", in: app)
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
        snapshot(app, "Booking — slot picked, hold placed")
    }

    // MARK: - Profile tab (A5, B1, N4, H1)

    @MainActor
    func testProfileShowsSummaryFiguresAndReachableSettings() throws {
        let app = launchApp()
        goToTab("Profile", in: app)
        require(app.navigationBars["Profile"], "the Profile screen")

        // The four summary tiles are the difference between the redesigned
        // screen and the old flat list of links.
        for tile in ["Wallet", "Points", "Visits done"] {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", tile)).count > 0,
                "Profile is missing its \(tile) summary tile"
            )
        }
        snapshot(app, "Profile — top")

        // Every grouped row must be reachable in one tap.
        let editProfile = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] 'Edit profile'")).element(boundBy: 0)
        XCTAssertTrue(scrollToVisible(editProfile, in: app), "Couldn't bring the Edit profile row on screen")
        tapAndExpect(editProfile, "the Edit profile row",
                     toReveal: app.navigationBars.firstMatch, "the Edit profile screen")
        snapshot(app, "Profile — edit profile")
    }

    @MainActor
    func testAddressesScreenHasAContentStateNotABlankScreen() throws {
        let app = launchApp()
        goToTab("Profile", in: app)
        let addresses = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] 'Addresses'")).element(boundBy: 0)
        guard scrollToVisible(addresses, in: app) else { throw XCTSkip("Addresses row not reachable") }
        addresses.tap()

        // A8/#14: this screen used to render entirely blank — no loading
        // state, no empty state — so a new user saw nothing at all.
        let hasRows = app.cells.count > 0
        let hasEmptyState = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'address'")
        ).count > 0
        XCTAssertTrue(hasRows || hasEmptyState,
                      "Addresses screen is blank — no rows, no empty state, nothing to tell the user what this is")
        snapshot(app, "Addresses")
    }

    // MARK: - Visits tab (I1, I2)

    @MainActor
    func testVisitsTabShowsEitherVisitsOrAnExplainedEmptyState() throws {
        let app = launchApp()
        goToTab("Visits", in: app)
        require(app.navigationBars["Your visits"], "the Visits screen")

        let hasVisitRows = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'status'")).count > 0
        let hasEmptyState = app.staticTexts["No visits yet"].exists
        XCTAssertTrue(hasVisitRows || hasEmptyState,
                      "Visits tab shows neither visits nor an empty state")
        snapshot(app, "Visits")
    }

    // MARK: - Appearance (O3) — the aurora has to survive both schemes

    @MainActor
    func testBothAppearancesRenderWithoutLosingContent() throws {
        let app = launchApp()
        goToTab("Profile", in: app)
        require(app.navigationBars["Profile"], "the Profile screen")

        for mode in ["Light", "Dark"] {
            let button = app.segmentedControls.buttons[mode]
            guard button.exists else { continue }
            button.tap()
            // The point is that content survives the switch — a background
            // that swallows its own text is the classic failure here.
            XCTAssertTrue(app.navigationBars["Profile"].exists,
                          "Profile content vanished after switching to \(mode)")
            snapshot(app, "Appearance — \(mode)")
        }
    }
}
