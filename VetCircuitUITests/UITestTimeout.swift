import Foundation

/// How long a UI test waits for a screen to appear.
///
/// This was 10 seconds everywhere. That number was never measured; it was
/// just a round one, and on this CI runner it sits right on the edge.
///
/// The evidence for that is the wall time of the walkthrough suite across
/// runs carrying near-identical code: 494s, 699s, 942s, 1038s. A better
/// than twofold swing, on a software-rendered simulator, with no code
/// change to explain it. Whichever screen happened to be opening during a
/// slow stretch is the one that failed, which is why the failing test kept
/// moving - Addresses, then Wallet, then Notifications - and why a test
/// that passed in one run failed in the next with nothing changed between
/// them.
///
/// Raising this does not weaken what the suite asserts. The bug it exists
/// to catch is a tap that does nothing - the "tap it three times" report -
/// and a tap that does nothing never opens the screen, however long you
/// wait. So a real defect still fails here; only a slow runner stops
/// failing.
enum UITestTimeout {
    /// Waiting for a pushed screen, a popped screen, or a tab to appear.
    static let navigation: TimeInterval = 40
}
