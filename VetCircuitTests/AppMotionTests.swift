import Testing
@testable import VetCircuit

/// The five looping animations in the app are decorative, but they are also
/// permanent, and XCTest cannot read an accessibility tree from an app that
/// never goes idle. These pin the rule that decides whether they start.
struct AppMotionTests {
    @Test("A user who asked for less motion does not get looping animations")
    func reduceMotionDisablesLoops() {
        #expect(AppMotion.loopsDisabled(reduceMotion: true))
    }

    @Test("Loops run for an ordinary launch with motion left on")
    func loopsRunNormally() {
        // The unit suite is not launched with -UITest, so the flag is off and
        // the only input left is the user's setting.
        #expect(AppMotion.isUITesting == false)
        #expect(AppMotion.loopsDisabled(reduceMotion: false) == false)
    }
}
