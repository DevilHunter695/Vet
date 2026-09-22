import Foundation

/// Whether looping, never-ending animations should run at all.
///
/// Five places in the app start a `repeatForever` animation on appear - the
/// aurora drift, the shimmer, the mascot bounce, and the two live pulses.
/// They are decorative, and they are also permanent: XCTest waits for an
/// app to go idle before it can read the accessibility tree, and an app
/// with a perpetual animation running never does. That is what
/// "Failed to get matching snapshots: Timed out while evaluating UI query"
/// means in the UI suite.
///
/// The UI tests already launch with `-UITest`; nothing was reading it. Now
/// it turns the loops off, so the runner sees a still screen.
enum AppMotion {
    /// True when the process was launched by the UI test runner.
    static let isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("-UITest")

    /// True when a looping animation should not be started.
    /// `reduceMotion` is the user's own setting; the test flag is ours.
    static func loopsDisabled(reduceMotion: Bool) -> Bool {
        reduceMotion || isUITesting
    }
}
