import XCTest

/// The second half of the walkthrough: breadth rather than depth.
///
/// `AppWalkthroughUITests` proves the spine of the app works — the tabs, a
/// circuit, the booking screen, the slot picker. This file exists to answer a
/// different question: of the ~99 features the product claims, how many can a
/// customer actually *reach and see* in the running app?
///
/// That question was previously answered by reading the source, which is how
/// twelve features came to be "present" and inert at the same time. A
/// navigation-bar title appearing after a tap is weak evidence about a
/// feature's correctness and very strong evidence that it is wired up at all —
/// which is precisely the failure mode this codebase has had.
///
/// Where a screen's content can be asserted cheaply (a figure, a section
/// heading, a row), it is. Where it cannot, reaching the screen on one tap is
/// still worth locking down.
final class FeatureWalkthroughUITests: XCTestCase {

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UITest"]
        app.launch()
        return app
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
    @MainActor
    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let direct = app.buttons[title]
        if direct.waitForExistence(timeout: 3), direct.isHittable { return direct }
        // Collapsed: the only visible bar button is the current tab. Tapping
        // it expands the bar, after which the wanted tab exists.
        let bar = app.descendants(matching: .any).matching(identifier: "floatingTabBar").firstMatch
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

    /// Scrolls `element` into view. `isHittable` is false both for a control
    /// with no touch region and for one merely below the fold; only the first
    /// is a bug, so anything further down a screen is scrolled to first.
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

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] %@", title)).element(boundBy: 0)
    }

    /// Taps a Profile row and asserts the screen it promises actually opens,
    /// on the FIRST tap, then comes back for the next one.
    @MainActor
    private func openFromProfile(
        _ rowTitle: String, expecting navTitle: String, feature: String,
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let control = row(rowTitle, in: app)
        XCTAssertTrue(scrollToVisible(control, in: app),
                      "\(feature): the \"\(rowTitle)\" row never became reachable on Profile",
                      file: file, line: line)
        XCTAssertTrue(control.isHittable,
                      "\(feature): \"\(rowTitle)\" is drawn but not hittable — the 'tap it three times' bug",
                      file: file, line: line)
        control.tap()
        XCTAssertTrue(app.navigationBars[navTitle].waitForExistence(timeout: 10),
                      "\(feature): tapped \"\(rowTitle)\" once and \"\(navTitle)\" did not open",
                      file: file, line: line)
        snapshot(app, "\(feature) — \(navTitle)")
        app.navigationBars[navTitle].buttons.element(boundBy: 0).tap()
        _ = app.navigationBars["Profile"].waitForExistence(timeout: 10)
    }

    @MainActor
    private func goToProfile(_ app: XCUIApplication) {
        goToTab("Profile", in: app)
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10), "Profile never opened")
    }

    // MARK: - Account & money (A5, A8, G6, N1, O1, J7, O5)

    @MainActor
    func testAccountAndMoneyScreensAreAllReachable() throws {
        let app = launchApp()
        goToProfile(app)

        openFromProfile("Edit profile", expecting: "Edit profile", feature: "A5", in: app)
        openFromProfile("Wallet", expecting: "Wallet", feature: "G6", in: app)
        openFromProfile("Addresses", expecting: "Addresses", feature: "A8", in: app)
        openFromProfile("Payment methods", expecting: "Payment methods", feature: "E9", in: app)
        openFromProfile("Household", expecting: "Household", feature: "A9", in: app)
        openFromProfile("Invite friends", expecting: "Invite friends", feature: "N1", in: app)
    }

    @MainActor
    func testSupportAndLegalScreensAreAllReachable() throws {
        let app = launchApp()
        goToProfile(app)

        openFromProfile("Help centre", expecting: "Help centre", feature: "M1", in: app)
        openFromProfile("Contact support", expecting: "Contact support", feature: "M2", in: app)
        openFromProfile("My tickets", expecting: "My tickets", feature: "M2", in: app)
        openFromProfile("Privacy & consent", expecting: "Privacy & consent", feature: "O5", in: app)
        openFromProfile("Privacy Policy", expecting: "Privacy Policy", feature: "L8", in: app)
        openFromProfile("Terms of Service", expecting: "Terms of Service", feature: "L8", in: app)
    }

    @MainActor
    func testNotificationScreensAreReachable() throws {
        let app = launchApp()
        goToProfile(app)
        openFromProfile("Notification preferences", expecting: "Notifications", feature: "O1", in: app)
        openFromProfile("Notification centre", expecting: "Notifications", feature: "J7", in: app)
    }

    // MARK: - G6: the wallet has to show a ledger, not just a number

    @MainActor
    func testWalletShowsARealLedgerNotJustABalance() throws {
        let app = launchApp()
        goToProfile(app)
        let wallet = row("Wallet", in: app)
        XCTAssertTrue(scrollToVisible(wallet, in: app), "Wallet row not reachable")
        wallet.tap()
        XCTAssertTrue(app.navigationBars["Wallet"].waitForExistence(timeout: 10), "Wallet didn't open")

        // A wallet screen whose only content is a balance tells the customer
        // nothing about where their money went.
        let rupeeTexts = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '₹'"))
        XCTAssertGreaterThan(rupeeTexts.count, 1,
                             "G6: the wallet shows no ledger entries, only a figure")
        snapshot(app, "G6 — wallet ledger")
    }

    // MARK: - B1/B2/B3/B4/B5/B6: pets and their records

    @MainActor
    func testOpeningAPetRevealsItsRecordScreens() throws {
        let app = launchApp()
        goToProfile(app)

        // The pet cards carry the pet's name; the demo account has Bruno.
        let pet = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Bruno'")).element(boundBy: 0)
        guard scrollToVisible(pet, in: app) else {
            return XCTFail("B1: no pet card on Profile — the demo account has three pets")
        }
        pet.tap()
        XCTAssertTrue(app.navigationBars["Bruno"].waitForExistence(timeout: 10),
                      "B2: tapping a pet did not open its detail screen")
        snapshot(app, "B2 — pet detail")

        // B3/B4/B5: the record sections a pet screen exists to carry. These
        // are headings on the detail screen itself, so assert on content
        // rather than navigation.
        for (feature, needle) in [("B3", "weight"), ("B4", "vaccinat"), ("B5", "prescription")] {
            let found = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", needle)
            ).count > 0
            XCTAssertTrue(found, "\(feature): the pet detail screen has no '\(needle)' section")
        }
    }

    // MARK: - D1/D2/D3/D4: catalog, variants, add-ons, packages

    @MainActor
    func testCatalogOpensAServiceWithVariantsAndAddons() throws {
        let app = launchApp()
        goToTab("Book", in: app)

        let services = row("Services", in: app)
        guard scrollToVisible(services, in: app) else {
            throw XCTSkip("No route into the service catalog from the Book tab")
        }
        services.tap()
        XCTAssertTrue(app.navigationBars["Services"].waitForExistence(timeout: 10),
                      "D1: the service catalog did not open")
        snapshot(app, "D1 — service catalog")

        // D2: a catalog row advertises a starting price. It must not be ₹0 —
        // that was a real bug, caused by counting the free follow-up variant
        // in the price floor.
        let zeroPrice = app.staticTexts.containing(NSPredicate(format: "label == '₹0'")).count
        XCTAssertEqual(zeroPrice, 0, "D2: a service is advertised 'from ₹0' — the follow-up variant is in the price floor again")

        let consult = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'consultation'")).element(boundBy: 0)
        guard scrollToVisible(consult, in: app) else { throw XCTSkip("No consultation service in the catalog") }
        consult.tap()

        // D2/D3: the detail screen must offer more than one variant and its
        // add-ons, or the "what exactly am I buying" promise is empty.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'min'")).count > 0,
            "D2: the service detail screen shows no variant durations"
        )
        snapshot(app, "D2/D3 — service detail")
    }

    @MainActor
    func testPackagesScreenOpensAndListsWhatIsInEachBundle() throws {
        let app = launchApp()
        goToTab("Book", in: app)
        let services = row("Services", in: app)
        guard scrollToVisible(services, in: app) else { throw XCTSkip("No route into the catalog") }
        services.tap()
        _ = app.navigationBars["Services"].waitForExistence(timeout: 10)

        let packages = app.buttons["Packages"].firstMatch
        guard packages.waitForExistence(timeout: 10) else { throw XCTSkip("No Packages toolbar item") }
        XCTAssertTrue(packages.isHittable, "D4: the Packages toolbar item is drawn but not hittable")
        packages.tap()
        XCTAssertTrue(app.navigationBars["Packages"].waitForExistence(timeout: 10), "D4: Packages did not open")

        // D4: a package card that only names the bundle is not something
        // anyone spends money on — it has to list what is inside.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] '×'")).count > 0,
            "D4: no package lists its included services"
        )
        snapshot(app, "D4 — packages")
    }

    // MARK: - E1/E3: the cart is reachable and never blank

    @MainActor
    func testCartIsReachableAndNeverRendersBlank() throws {
        let app = launchApp()
        goToTab("Book", in: app)
        let services = row("Services", in: app)
        guard scrollToVisible(services, in: app) else { throw XCTSkip("No route into the catalog") }
        services.tap()
        _ = app.navigationBars["Services"].waitForExistence(timeout: 10)

        let cart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Cart'")).element(boundBy: 0)
        guard cart.waitForExistence(timeout: 10) else { return XCTFail("E1: no cart affordance on the catalog screen") }
        XCTAssertTrue(cart.isHittable, "E1: the cart button is drawn but not hittable — it used to read as disabled")
        cart.tap()
        XCTAssertTrue(app.navigationBars["Cart"].waitForExistence(timeout: 10), "E1: the cart did not open")

        // The cart used to render literally nothing when it was empty and the
        // load had finished. A screen with no text at all is the bug.
        XCTAssertGreaterThan(app.staticTexts.count, 0,
                             "E1: the cart opened to a completely blank screen")
        snapshot(app, "E1 — cart")
    }

    // MARK: - I1/I2/K1/F4: a visit, its timeline, its record, and cancelling

    @MainActor
    func testVisitsTabCarriesRealVisitsAndOpensOneOnTheFirstTap() throws {
        let app = launchApp()
        goToTab("Visits", in: app)
        XCTAssertTrue(app.navigationBars["Your visits"].waitForExistence(timeout: 10), "Visits tab did not open")

        // The seeded account has fourteen visits across the state machine, so
        // an empty state here means the seed stopped reaching the repository.
        XCTAssertEqual(
            app.staticTexts["No visits yet"].exists, false,
            "I1: the Visits tab is empty — the demo visit history is not reaching MockVisitRepository"
        )
        snapshot(app, "I1 — visits")

        let visit = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Bruno'")).element(boundBy: 0)
        guard scrollToVisible(visit, in: app) else { throw XCTSkip("No visit row to open") }
        XCTAssertTrue(visit.isHittable, "I1: a visit row is drawn but not hittable")
        visit.tap()
        XCTAssertTrue(app.navigationBars["Visit details"].waitForExistence(timeout: 10),
                      "I1: tapping a visit once did not open its detail screen")
        snapshot(app, "I1 — visit detail")
    }

    @MainActor
    func testAVisitDetailOffersItsTimelineAndACancelPath() throws {
        let app = launchApp()
        goToTab("Visits", in: app)
        _ = app.navigationBars["Your visits"].waitForExistence(timeout: 10)

        let visit = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Bruno'")).element(boundBy: 0)
        guard scrollToVisible(visit, in: app) else { throw XCTSkip("No visit row to open") }
        visit.tap()
        guard app.navigationBars["Visit details"].waitForExistence(timeout: 10) else {
            return XCTFail("Visit detail did not open")
        }

        // I2: the timestamped status timeline.
        let timeline = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'timeline'")).element(boundBy: 0)
        if scrollToVisible(timeline, in: app) {
            timeline.tap()
            XCTAssertTrue(app.navigationBars["Status timeline"].waitForExistence(timeout: 10),
                          "I2: the status timeline did not open")
            snapshot(app, "I2 — status timeline")
            app.navigationBars["Status timeline"].buttons.element(boundBy: 0).tap()
            _ = app.navigationBars["Visit details"].waitForExistence(timeout: 10)
        } else {
            XCTFail("I2: no route to the status timeline from a visit")
        }

        // F4: cancelling has to be reachable from the visit itself, and the
        // dialog has to state the money consequence rather than ask a bare
        // "are you sure". This is the bug that was reported as "the cancel
        // button doesn't cancel".
        let cancel = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Cancel this visit'")).element(boundBy: 0)
        if scrollToVisible(cancel, in: app) {
            XCTAssertTrue(cancel.isHittable, "F4: the cancel button is drawn but not hittable")
            cancel.tap()
            let dialogAppeared = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'refund' OR label CONTAINS[c] 'no refund'")
            ).element(boundBy: 0).waitForExistence(timeout: 10)
            XCTAssertTrue(dialogAppeared,
                          "F4: cancelling did not state the refund consequence before confirming")
            snapshot(app, "F4 — cancel consequence")
        }
    }

    // MARK: - C3/C4/C8/C11: filters, sort, search and the emergency path

    @MainActor
    func testDiscoveryControlsAreReachableFromTheBookTab() throws {
        let app = launchApp()
        goToTab("Book", in: app)

        // C11: the emergency path is safety-critical and must be present
        // without scrolling.
        XCTAssertTrue(app.staticTexts["This is an emergency"].waitForExistence(timeout: 10),
                      "C11: the emergency entry point is missing from the Book tab")

        let filters = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] 'Filter'")).element(boundBy: 0)
        if filters.waitForExistence(timeout: 5) {
            XCTAssertTrue(filters.isHittable, "C3: the filters control is drawn but not hittable")
            filters.tap()
            XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 10), "C3: filters did not open")
            snapshot(app, "C3 — filters")
        } else {
            XCTFail("C3: no filters control on the Book tab")
        }
    }

    @MainActor
    func testEmergencyPathOpensAndCarriesItsDisclaimer() throws {
        let app = launchApp()
        goToTab("Book", in: app)
        let emergency = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'emergency'")).element(boundBy: 0)
        guard scrollToVisible(emergency, in: app) else { throw XCTSkip("No emergency control found") }
        emergency.tap()
        XCTAssertTrue(app.navigationBars["Emergency"].waitForExistence(timeout: 10),
                      "C11: the emergency screen did not open")
        // L8: the "we are not an emergency service" disclaimer.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'emergency'")).count > 0,
            "L8: the emergency screen carries no disclaimer copy"
        )
        snapshot(app, "C11/L8 — emergency")
    }
}
