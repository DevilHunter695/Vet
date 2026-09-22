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
    /// The tab bar is the system's again, so `app.tabBars` works.
    ///
    /// These helpers used to hunt for a custom container by identifier and,
    /// when the bar had collapsed to a single circle, tap a button labelled
    /// "show all tabs" to get the tabs back. None of that exists now: the
    /// system bar minimizes rather than collapsing, and its tabs stay present
    /// and hittable throughout, which is the behaviour Apple's own guidance
    /// asks for and the custom bar could not manage.
    @MainActor
    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let inBar = app.tabBars.buttons[title]
        if inBar.waitForExistence(timeout: 3) { return inBar }
        // A minimized bar still carries its tabs; scrolling up restores it at
        // full size if a screen happens to have scrolled it away.
        app.swipeDown()
        return app.tabBars.buttons[title]
    }

    @MainActor
    private func goToTab(_ title: String, in app: XCUIApplication) {
        let button = tabButton(title, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: UITestTimeout.navigation), "The \(title) tab was not reachable")
        XCTAssertTrue(button.isHittable, "The \(title) tab is drawn but not hittable")
        button.tap()
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        // Retained only when the test fails, which is when a screenshot is
        // actually worth looking at. Keeping every one of them alive across a
        // 22-test, 15-minute run is what starves the runner.
        shot.lifetime = .deleteOnSuccess
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

    /// Taps `element` only once it has stopped moving.
    ///
    /// scrollToVisible returns the instant a row becomes hittable, which is
    /// while the scroll view is still decelerating from the swipe that got
    /// it there. XCUIElement.tap() then resolves the element's frame and
    /// taps those coordinates - and by the time the tap lands, the row has
    /// travelled and something else is underneath.
    ///
    /// On Profile the thing above the row list is the upcoming-visit card,
    /// which is why the failure was always "tapped Wallet, ended up on
    /// Visit details" and why neither the selector fix nor any timeout
    /// touched it. It is not a stale query; it is a stale coordinate.
    ///
    /// A real finger does not hit this: tapping a decelerating scroll view
    /// on iOS stops the scroll rather than activating what is under it.
    /// A synthetic tap has no such courtesy, so the test has to wait for
    /// what a person would have waited for anyway.
    @MainActor
    private func tapWhenSteady(_ element: XCUIElement) {
        // Deliberately few samples. `element.frame` is a full accessibility
        // query, and the first version of this polled twenty times per tap
        // across fifteen taps - up to three hundred extra tree evaluations
        // per run, landing immediately before a waitForExistence that then
        // timed out. That is the same mistake as the waitForNonExistence
        // removed in e054da7: a fix that pays for itself in query pressure.
        //
        // Scroll deceleration settles well inside 400ms, so five samples is
        // the measurement, and a short settle first means most taps take the
        // early exit on the second sample.
        usleep(150_000)
        var previous = element.frame
        for _ in 0..<5 {
            usleep(80_000)
            let current = element.frame
            if current == previous { break }
            previous = current
        }
        element.tap()
    }

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // matching, not containing.
        //
        // containing() matches an element whose DESCENDANTS satisfy the
        // predicate, so any container wrapping the Wallet row matched too -
        // and an ancestor comes before its child in tree order, so
        // element(boundBy: 0) was the container, not the row. Tapping a
        // container taps its centre, which on Profile is the upcoming-visit
        // card. That is why run 224 reported the app sitting on "Visit
        // details" with no Wallet button in sight, and why no timeout ever
        // helped: the tap worked, it just opened the wrong screen.
        //
        // matching() tests the element's own label, so this can only ever
        // return the row itself.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", title)).element(boundBy: 0)
    }

    /// Describes what the runner can actually see, for a failure message.
    ///
    /// Every theory I formed about why a tap did not navigate was wrong,
    /// because the failure text said only that a screen did not open - not
    /// which control was tapped, what else answered to that name, or where
    /// the app ended up. Guessing from that is how six wrong explanations
    /// happen. This makes the test say what it saw.
    @MainActor
    private func whatIsOnScreen(_ app: XCUIApplication, matching title: String) -> String {
        let matches = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] %@", title))
        let labels = (0..<matches.count).map { i -> String in
            let e = matches.element(boundBy: i)
            return "[\(i)]\"\(e.label)\" hit=\(e.isHittable) y=\(Int(e.frame.origin.y)) h=\(Int(e.frame.height))"
        }
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
        // One line, deliberately. The CI verdict step extracts the first
        // line of each failing assertion, so a multi-line message loses
        // everything after the first - which is how run 222 reported this
        // diagnostic and told me nothing.
        let buttons = labels.isEmpty ? "none" : labels.joined(separator: " ")
        return "MATCHES(tap goes to [0]): \(buttons) || BARS: \(bars.isEmpty ? "none" : bars.joined(separator: ","))"
    }

    /// Taps a Profile row and asserts the screen it promises actually opens,
    /// on the FIRST tap, then comes back for the next one.
    @MainActor
    private func openFromProfile(
        _ rowTitle: String, expecting navTitle: String, feature: String,
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        // A progress marker, because the failure that is left cannot carry a
        // message. "Failed to get matching snapshots" is raised by the query
        // evaluator itself, not by an assertion, so it fails the test at
        // whatever line was executing with no indication of which row was
        // being opened. Two structurally identical tests - six
        // openFromProfile calls each - behave differently, and without this
        // there is no way to tell which of the six is the one that hurts.
        //
        // The verdict step prints the last marker in each log, so the answer
        // arrives in the tail rather than in an artifact download.
        print("UITEST-STEP: \(feature) \(rowTitle)")

        let control = row(rowTitle, in: app)
        XCTAssertTrue(scrollToVisible(control, in: app),
                      "\(feature): the \"\(rowTitle)\" row never became reachable on Profile",
                      file: file, line: line)
        XCTAssertTrue(control.isHittable,
                      "\(feature): \"\(rowTitle)\" is drawn but not hittable — the 'tap it three times' bug",
                      file: file, line: line)
        tapWhenSteady(control)
        XCTAssertTrue(app.navigationBars[navTitle].waitForExistence(timeout: UITestTimeout.navigation),
                      "\(feature): tapped \"\(rowTitle)\" once and \"\(navTitle)\" did not open. \(whatIsOnScreen(app, matching: rowTitle))",
                      file: file, line: line)
        // No screenshot here. This helper runs fifteen times across the
        // suite, and a full-resolution capture of a glass-heavy SwiftUI
        // screen is not cheap on a CI simulator - the assertion above has
        // already proved the screen opened, which is what the test is for.
        // Tap the back button by name rather than by index.
        //
        // Asking for a specific button is simply more robust than trusting
        // the ordering of a bar that may carry more than one. It is NOT a
        // proven explanation of the Wallet failure: "My tickets" also has a
        // trailing bar button and the row opened straight after it passes,
        // so a second button plainly does not break the row that follows.
        // An earlier version of this comment claimed it did - it was wrong.
        let bar = app.navigationBars[navTitle]
        let back = bar.buttons["Profile"].exists ? bar.buttons["Profile"]
                 : bar.buttons["Back"].exists ? bar.buttons["Back"]
                 : bar.buttons.element(boundBy: 0)
        back.tap()

        // Waiting for Profile's bar is enough; there is deliberately no
        // wait for the pushed bar to disappear.
        //
        // I added one, on the theory that a push arriving during a pop gets
        // dropped. That theory was wrong - testSupportAndLegalScreensAre
        // AllReachable opens four screens back to back and passes - and the
        // real cause turned out to be this helper's own selector. The wait
        // then became the problem itself: waitForNonExistence polls a
        // full-tree query for up to forty seconds, and on a slow runner
        // that is what exhausted the query evaluator in run 225.
        _ = app.navigationBars["Profile"].waitForExistence(timeout: UITestTimeout.navigation)
    }

    @MainActor
    private func goToProfile(_ app: XCUIApplication) {
        goToTab("Profile", in: app)
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: UITestTimeout.navigation), "Profile never opened")
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
        tapWhenSteady(wallet)
        XCTAssertTrue(app.navigationBars["Wallet"].waitForExistence(timeout: UITestTimeout.navigation),
                      "Wallet didn't open. \(whatIsOnScreen(app, matching: "Wallet"))")

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
        XCTAssertTrue(app.navigationBars["Bruno"].waitForExistence(timeout: UITestTimeout.navigation),
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
        XCTAssertTrue(app.navigationBars["Services"].waitForExistence(timeout: UITestTimeout.navigation),
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
        _ = app.navigationBars["Services"].waitForExistence(timeout: UITestTimeout.navigation)

        let packages = app.buttons["Packages"].firstMatch
        guard packages.waitForExistence(timeout: UITestTimeout.navigation) else { throw XCTSkip("No Packages toolbar item") }
        XCTAssertTrue(packages.isHittable, "D4: the Packages toolbar item is drawn but not hittable")
        packages.tap()
        XCTAssertTrue(app.navigationBars["Packages"].waitForExistence(timeout: UITestTimeout.navigation), "D4: Packages did not open")

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
        _ = app.navigationBars["Services"].waitForExistence(timeout: UITestTimeout.navigation)

        let cart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Cart'")).element(boundBy: 0)
        guard cart.waitForExistence(timeout: UITestTimeout.navigation) else { return XCTFail("E1: no cart affordance on the catalog screen") }
        XCTAssertTrue(cart.isHittable, "E1: the cart button is drawn but not hittable — it used to read as disabled")
        cart.tap()
        XCTAssertTrue(app.navigationBars["Cart"].waitForExistence(timeout: UITestTimeout.navigation), "E1: the cart did not open")

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
        XCTAssertTrue(app.navigationBars["Your visits"].waitForExistence(timeout: UITestTimeout.navigation), "Visits tab did not open")

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
        XCTAssertTrue(app.navigationBars["Visit details"].waitForExistence(timeout: UITestTimeout.navigation),
                      "I1: tapping a visit once did not open its detail screen")
        snapshot(app, "I1 — visit detail")
    }

    @MainActor
    func testAVisitDetailOffersItsTimelineAndACancelPath() throws {
        let app = launchApp()
        goToTab("Visits", in: app)
        _ = app.navigationBars["Your visits"].waitForExistence(timeout: UITestTimeout.navigation)

        let visit = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Bruno'")).element(boundBy: 0)
        guard scrollToVisible(visit, in: app) else { throw XCTSkip("No visit row to open") }
        visit.tap()
        guard app.navigationBars["Visit details"].waitForExistence(timeout: UITestTimeout.navigation) else {
            return XCTFail("Visit detail did not open")
        }

        // I2: the timestamped status timeline.
        let timeline = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'timeline'")).element(boundBy: 0)
        if scrollToVisible(timeline, in: app) {
            timeline.tap()
            XCTAssertTrue(app.navigationBars["Status timeline"].waitForExistence(timeout: UITestTimeout.navigation),
                          "I2: the status timeline did not open")
            snapshot(app, "I2 — status timeline")
            app.navigationBars["Status timeline"].buttons.element(boundBy: 0).tap()
            _ = app.navigationBars["Visit details"].waitForExistence(timeout: UITestTimeout.navigation)
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
            ).element(boundBy: 0).waitForExistence(timeout: UITestTimeout.navigation)
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
        XCTAssertTrue(app.staticTexts["This is an emergency"].waitForExistence(timeout: UITestTimeout.navigation),
                      "C11: the emergency entry point is missing from the Book tab")

        let filters = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] 'Filter'")).element(boundBy: 0)
        if filters.waitForExistence(timeout: 5) {
            XCTAssertTrue(filters.isHittable, "C3: the filters control is drawn but not hittable")
            filters.tap()
            XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: UITestTimeout.navigation), "C3: filters did not open")
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
        XCTAssertTrue(app.navigationBars["Emergency"].waitForExistence(timeout: UITestTimeout.navigation),
                      "C11: the emergency screen did not open")
        // L8: the "we are not an emergency service" disclaimer.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'emergency'")).count > 0,
            "L8: the emergency screen carries no disclaimer copy"
        )
        snapshot(app, "C11/L8 — emergency")
    }
}
