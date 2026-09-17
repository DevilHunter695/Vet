import SwiftUI

// MARK: - Hiding the tab bar on screens that own the bottom of the display
//
// What remains of a file that used to hand-roll an entire tab bar.
//
// The custom bar existed because the system could not do what this app
// wanted below iOS 26: genuine Liquid Glass, a bar that minimizes as you
// scroll, and an accessory riding along with it. All three are system
// behaviour now, so the bar, its scroll-offset plumbing, its collapse state
// machine and its press styles are gone — see `MainTabView`.
//
// This is the one piece that does not come for free: a pushed screen with
// its own bottom action bar still has to say so, because two bars stacked at
// the bottom is one too many and the tab bar wins the position that belongs
// to the commit button. It is opt-in per screen rather than automatic on
// push, because "did the user drill in" is not the question — "does this
// screen already own the bottom" is.

extension View {
    /// Hides the tab bar for a screen that owns the bottom of the display.
    ///
    /// Now a thin wrapper over the system modifier. It keeps its own name so
    /// the handful of screens using it did not all have to change, and so
    /// the intent still reads at the call site: this is not "hide chrome",
    /// it is "this screen has its own bottom bar".
    func hidesFloatingTabBar() -> some View {
        toolbar(.hidden, for: .tabBar)
    }
}
