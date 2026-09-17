import SwiftUI
import UIKit

// MARK: - The floating tab bar
//
// Replaces `TabView`'s system bar, which is an opaque strip that permanently
// eats ~83pt of every screen and cannot be made translucent beyond what the
// system decides. This one floats, is mostly transparent, and gets out of the
// way while you read.
//
// Three behaviours worth naming, because each is a deliberate choice:
//
//  1. **Every tab is labelled, with the icon stacked above the word.** An
//     earlier version of this bar showed the label only on the selected tab,
//     to keep it narrow. That trades away the thing a tab bar is for: an
//     unlabelled glyph is a guess, and you should not have to tap a tab to
//     find out what it is. The bar is wide instead, and the selected item is
//     marked by a pill rather than by being the only one you can read.
//  2. **It collapses when you scroll down and returns when you scroll up.**
//     Reading is the moment you want the chrome gone; reaching for
//     navigation is the moment you want it back, and scrolling up is what
//     people do just before they navigate. Same behaviour as Apple Music's.
//  3. **Content scrolls under it, not around it.** A translucent layer that
//     reserves its own strip is just an opaque bar with extra steps.

struct TabItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let icon: String
    let selectedIcon: String
}

@MainActor
@Observable
final class TabBarChrome {
    /// Collapsed to a single circle. Driven by scroll direction, and by the
    /// user tapping the collapsed circle to bring it back.
    var isCollapsed = false

    private var lastOffset: CGFloat = 0
    /// Movement under this is noise — a finger resting on a list, a bounce at
    /// the top. Without hysteresis the bar flickers between states while
    /// somebody is just holding still.
    private let threshold: CGFloat = 12

    /// `TabBarChrome` is a plain `@Observable` object, not a `View`, so it has
    /// no `\.accessibilityReduceMotion` environment value to read. Reduce
    /// Motion is a system-wide setting, so asking UIKit directly here is the
    /// straightforward way for non-view code to still honor it.
    private var chromeSpring: Animation {
        UIAccessibility.isReduceMotionEnabled
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.38, dampingFraction: 0.82)
    }

    func scrollOffsetChanged(_ offset: CGFloat) {
        let delta = offset - lastOffset
        guard abs(delta) > threshold else { return }
        lastOffset = offset
        // `offset` decreases as content moves up, so a negative delta is
        // scrolling *down* into the content.
        let shouldCollapse = delta < 0
        guard shouldCollapse != isCollapsed else { return }
        withAnimation(chromeSpring) {
            isCollapsed = shouldCollapse
        }
    }

    /// Near the top of a list the bar should always be available — there is
    /// nothing to read up there and a collapsed bar just looks broken.
    func resetIfAtTop(_ offset: CGFloat) {
        guard offset > -40, isCollapsed else { return }
        withAnimation(chromeSpring) { isCollapsed = false }
    }

    func expand() {
        guard isCollapsed else { return }
        withAnimation(chromeSpring) { isCollapsed = false }
    }

    /// A count, not a flag. Two screens that both hide the bar can overlap
    /// during a push transition, and with a boolean the one disappearing
    /// turns the bar back on over the one that just asked for it gone.
    private(set) var hiddenRequestCount = 0

    func beginHiding() {
        withAnimation(chromeSpring) { hiddenRequestCount += 1 }
    }

    func endHiding() {
        withAnimation(chromeSpring) {
            hiddenRequestCount = max(0, hiddenRequestCount - 1)
        }
    }
}

struct FloatingTabBar: View {
    @Binding var selection: Int
    let items: [TabItem]
    var chrome: TabBarChrome
    /// What the bar minimizes *around* — see `TabBarAccessoryModel`. Nil most
    /// of the time; present while a visit is actually happening.
    var accessory: TabBarAccessoryModel?

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The cell below is a *fixed* 56pt tall — deliberately, because this bar
    // floats over content and `FloatingChrome.tabBarInset` (Presentation/
    // Shared/LiquidGlass.swift) reserves exactly that much room for it. Letting
    // the cell grow with type size would either clip against that fixed inset
    // or, if the inset grew to match, push every screen's content down for
    // everyone, not just accessibility-size users. So at accessibility sizes
    // the icon-and-word layout gives way to icon-only instead of growing: the
    // label is still there for VoiceOver (`accessibilityLabel` is unchanged),
    // it's just not drawn under the glyph.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // MARK: Motion
    //
    // Apple Music's tab bar does not move like a menu appearing; it moves
    // like an object being pushed. The pill overshoots its target slightly
    // and settles back, which is what reads as weight. Apple's own guidance
    // is that overshoot belongs to momentum-carrying gestures and not to
    // taps — the exception it makes for itself, and the reason this one
    // earns it, is that the pill is *travelling across a distance* rather
    // than appearing in place, and motion across a distance without any
    // follow-through reads as a jump-cut.
    //
    // Springs are used rather than durations because they retarget from the
    // current on-screen value: tapping a third tab mid-flight redirects the
    // pill from wherever it actually is, instead of restarting it.

    /// The pill's travel. Bouncier and a touch slower than the old motion,
    /// which was nearly critically damped and so read as a slide rather than
    /// a throw.
    private var selectionSpring: Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.42, dampingFraction: 0.72)
    }

    /// Collapse/expand. Kept tighter than the pill: this one changes the
    /// bar's *size*, and a bouncing container is distracting in a way that a
    /// bouncing highlight inside it is not.
    private var collapseSpring: Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private var selectedItem: TabItem? { items.first { $0.id == selection } }

    /// Minimized *with something to inline*, which is the state Apple's
    /// guidance actually describes. Without an accessory there is nothing to
    /// move inline, and the bar falls back to the single-circle collapse.
    private var isMinimizedWithAccessory: Bool {
        chrome.isCollapsed && accessory != nil
    }

    private var hugsContent: Bool {
        chrome.isCollapsed && accessory == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Expanded: the accessory is a full-width strip above the tabs,
            // inside the same pane — one surface, two decks.
            if let accessory, !chrome.isCollapsed {
                TabBarAccessoryStrip(model: accessory)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                GlassSeam()
            }

            HStack(spacing: 4) {
                if isMinimizedWithAccessory, let accessory {
                    // Minimized: the accessory rides inline with the tabs,
                    // and the tabs stay tappable — Apple's own wording is
                    // that a person "can exit the minimized state by tapping
                    // a tab", which a bar collapsed to one circle makes
                    // impossible. Icons only, so the row still fits.
                    TabBarAccessoryInline(model: accessory)
                    Spacer(minLength: 0)
                    ForEach(items) { item in
                        minimizedTabButton(for: item)
                    }
                } else if chrome.isCollapsed, let selectedItem {
                    collapsedButton(for: selectedItem)
                } else {
                    ForEach(items) { item in
                        tabButton(for: item)
                    }
                }
            }
        }
        // Expanded, the bar is a wide slab that spreads its tabs across the
        // display like the system bar it replaces. Collapsed with nothing to
        // inline, it hugs the one circle it has left — so the width is state,
        // not a constant.
        .frame(maxWidth: hugsContent ? nil : CGFloat.infinity)
        .padding(.horizontal, hugsContent ? 6 : 8)
        .padding(.vertical, 8)
        // A findable name for the bar as a whole. It is no longer a system
        // `tabBar` element — it is a row of buttons — so anything looking for
        // it (the UI walkthrough, VoiceOver's rotor) needs a handle that does
        // not depend on the element type.
        .accessibilityIdentifier("floatingTabBar")
        .glassPanel(cornerRadius: barRadius, level: .chrome)
        // The whole bar is one glass surface, so it has to clip to the same
        // shape its background draws — otherwise the selection pill's corners
        // poke through the rim.
        .clipShape(RoundedRectangle(cornerRadius: barRadius, style: .continuous))
        .animation(collapseSpring, value: chrome.isCollapsed)
        .animation(collapseSpring, value: accessory)
        .animation(selectionSpring, value: selection)
        // The slab's inset from the display edges. Applied outside the glass
        // so it insets the surface itself; harmless when collapsed, because
        // the circle hugs and is centred regardless.
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Nearly half the expanded height, which is what gives the reference its
    /// almost-capsule ends without going fully capsule — a true `Capsule` on a
    /// bar this tall bows the ends out further than the shape reads as.
    private var barRadius: CGFloat { hugsContent ? 26 : 32 }

    /// The minimized row's tab: the glyph alone, at a full 44pt target.
    /// Tapping one both switches tab and restores the bar, which is the
    /// escape route the guidance requires.
    private func minimizedTabButton(for item: TabItem) -> some View {
        let isSelected = item.id == selection
        return Button {
            Haptics.selection()
            if !isSelected { selection = item.id }
            chrome.expand()
        } label: {
            Image(systemName: isSelected ? item.selectedIcon : item.icon)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isSelected ? Theme.primaryLight : Theme.textTertiary)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func tabButton(for item: TabItem) -> some View {
        let isSelected = item.id == selection
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            selection = item.id
        } label: {
            let glyph = Image(systemName: isSelected ? item.selectedIcon : item.icon)
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                // `contentTransition` morphs the outline glyph into the
                // filled one instead of blinking between them.
                .contentTransition(.symbolEffect(.replace))
                // …and the glyph gives a little kick as it lands. This is
                // the part that most reads as Apple Music: the symbol
                // itself acknowledges the tap, so the feedback comes from
                // the thing you pressed rather than only from the
                // highlight sliding over to it.
                .symbolEffect(.bounce, options: .speed(1.5), value: isSelected)
                // A small size pop on top of the bounce. Together they
                // make the selected icon the brightest, nearest thing in
                // the bar, which is what stops three similar glyphs
                // reading as one undifferentiated row.
                .scaleEffect(isSelected ? 1.10 : 1)
                .foregroundStyle(isSelected ? Theme.primaryLight : Theme.textTertiary)
                .frame(height: 24)

            Group {
                // At accessibility sizes even a `minimumScaleFactor(0.85)`
                // word does not fit under a 24pt glyph inside a fixed 56pt
                // cell — it clips. Rather than let the cell grow (see the
                // note on `dynamicTypeSize` above), the word drops out and
                // the icon alone stands for the tab.
                //
                // This is what UIKit's own tab bar does at these sizes, and
                // it is only half of what it does: the system pairs the
                // dropped title with the large content viewer, so a press
                // and hold puts the icon and the full label up in a HUD in
                // the middle of the screen. Without that half, somebody at
                // AX5 — the person most likely to need the word — is the one
                // person who cannot get at it. Apple's own guidance is
                // "include tab labels to help with navigation"; the viewer
                // is how that promise is kept when the label will not fit.
                if dynamicTypeSize.isAccessibilitySize {
                    glyph
                        .accessibilityShowsLargeContentViewer {
                            Label(item.title, systemImage: isSelected ? item.selectedIcon : item.icon)
                        }
                } else {
                    VStack(spacing: 5) {
                        glyph
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            // Small text wants a touch of positive tracking to
                            // stay legible; the old 14pt label was tightened
                            // instead, which is the right call at that size
                            // and the wrong one at this one.
                            .tracking(0.1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.15))
                        .overlay {
                            // The pill carries the same top-lit rim as every
                            // other glass surface in the app, so it reads as
                            // a raised pane within the bar rather than a
                            // painted rectangle on it.
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.30), .white.opacity(0.04)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 0.75
                                )
                        }
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            // 56pt of visible height comfortably clears the 44pt minimum.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func collapsedButton(for item: TabItem) -> some View {
        Button {
            Haptics.tap()
            chrome.expand()
        } label: {
            Image(systemName: item.selectedIcon)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel("\(item.title) tab. Double tap to show all tabs.")
    }
}

/// Press feedback on touch-down, not on release — the interface should
/// acknowledge the finger before it knows what the finger wants.
private struct TabPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(
                reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.22, dampingFraction: 1.0),
                value: configuration.isPressed
            )
    }
}

// MARK: - Getting out of the way on detail screens
//
// The bar floats above the whole `TabView`, so it is over pushed screens too.
// That is right for a list you drilled into — the tabs stay reachable — and
// wrong for any screen that owns a primary action bar of its own, because two
// floating bars stacked at the bottom is one too many and the tab bar wins the
// position that belongs to the commit button.
//
// Apple's own answer is the same: a detail screen with its own bottom chrome
// hides the tab bar. This is opt-in per screen rather than automatic on push,
// because "did the user drill in" is not the question — "does this screen
// already have a bottom bar" is.

extension TabBarChrome {
    /// Hidden entirely, for screens that own the bottom of the display.
    /// Separate from `isCollapsed`, which is about reading; this is about
    /// there being no room to share.
    var isHiddenForDetail: Bool { hiddenRequestCount > 0 }
}

private struct HidesFloatingTabBar: ViewModifier {
    @Environment(TabBarChrome.self) private var chrome: TabBarChrome?

    // `hiddenRequestCount` only stays correct if every `beginHiding()` this
    // modifier fires is matched by exactly one `endHiding()`. `onAppear`/
    // `onDisappear` are normally paired one-to-one by `NavigationStack`, but
    // this guard makes the pairing a property of the modifier itself rather
    // than an assumption about the transition: if `onAppear` were ever to
    // fire twice in a row (an interactive swipe-back that redrives the
    // transition, a view identity quirk) without a disappear between, the
    // second call is a no-op instead of a second increment — and the one
    // `onDisappear` that does eventually arrive still balances the single
    // increment that was actually made. An unmatched increment is otherwise
    // unrecoverable short of relaunching the app.
    @State private var isHiding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !isHiding else { return }
                isHiding = true
                chrome?.beginHiding()
            }
            .onDisappear {
                guard isHiding else { return }
                isHiding = false
                chrome?.endHiding()
            }
    }
}

extension View {
    /// Apply to any pushed screen with its own pinned bottom action bar.
    func hidesFloatingTabBar() -> some View {
        modifier(HidesFloatingTabBar())
    }
}
