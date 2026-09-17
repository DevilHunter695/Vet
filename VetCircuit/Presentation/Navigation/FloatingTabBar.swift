import SwiftUI

// MARK: - The floating tab bar
//
// Replaces `TabView`'s system bar, which is an opaque strip that permanently
// eats ~83pt of every screen and cannot be made translucent beyond what the
// system decides. This one floats, is mostly transparent, and gets out of the
// way while you read.
//
// Three behaviours worth naming, because each is a deliberate choice:
//
//  1. **The label only appears on the selected tab.** Three icons plus three
//     labels is a wide bar; three icons plus *one* label is a small one. The
//     selected item is also the one whose name you least need — so the label
//     is really there to confirm where you are, which is exactly the item
//     that should carry it.
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

    func scrollOffsetChanged(_ offset: CGFloat) {
        let delta = offset - lastOffset
        guard abs(delta) > threshold else { return }
        lastOffset = offset
        // `offset` decreases as content moves up, so a negative delta is
        // scrolling *down* into the content.
        let shouldCollapse = delta < 0
        guard shouldCollapse != isCollapsed else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            isCollapsed = shouldCollapse
        }
    }

    /// Near the top of a list the bar should always be available — there is
    /// nothing to read up there and a collapsed bar just looks broken.
    func resetIfAtTop(_ offset: CGFloat) {
        guard offset > -40, isCollapsed else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { isCollapsed = false }
    }

    func expand() {
        guard isCollapsed else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { isCollapsed = false }
    }

    /// A count, not a flag. Two screens that both hide the bar can overlap
    /// during a push transition, and with a boolean the one disappearing
    /// turns the bar back on over the one that just asked for it gone.
    private(set) var hiddenRequestCount = 0

    func beginHiding() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) { hiddenRequestCount += 1 }
    }

    func endHiding() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            hiddenRequestCount = max(0, hiddenRequestCount - 1)
        }
    }
}

struct FloatingTabBar: View {
    @Binding var selection: Int
    let items: [TabItem]
    var chrome: TabBarChrome

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        HStack(spacing: 2) {
            if chrome.isCollapsed, let selectedItem {
                collapsedButton(for: selectedItem)
            } else {
                ForEach(items) { item in
                    tabButton(for: item)
                }
            }
        }
        .padding(.horizontal, chrome.isCollapsed ? 6 : 7)
        .padding(.vertical, 6)
        // A findable name for the bar as a whole. It is no longer a system
        // `tabBar` element — it is a row of buttons — so anything looking for
        // it (the UI walkthrough, VoiceOver's rotor) needs a handle that does
        // not depend on the element type.
        .accessibilityIdentifier("floatingTabBar")
        .glassCapsule(level: .chrome)
        // The whole bar is one glass surface, so it has to clip to the same
        // capsule its background draws — otherwise the selection pill's
        // corners poke through the rim.
        .clipShape(Capsule(style: .continuous))
        .animation(collapseSpring, value: chrome.isCollapsed)
        .animation(selectionSpring, value: selection)
        .padding(.bottom, 6)
    }

    private func tabButton(for item: TabItem) -> some View {
        let isSelected = item.id == selection
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            selection = item.id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? item.selectedIcon : item.icon)
                    .font(.system(size: 16, weight: .semibold))
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
                    .scaleEffect(isSelected ? 1.08 : 1)

                if isSelected {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .tracking(-0.1)
                        .fixedSize()
                        // The label unfurls from the icon rather than fading
                        // in over it: it scales out horizontally from its
                        // leading edge, anchored where the icon sits, so the
                        // bar reads as widening to make room for a word
                        // instead of a word materialising in a gap.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4, anchor: .leading)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.6, anchor: .leading)
                                .combined(with: .opacity)
                        ))
                }
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, isSelected ? 14 : 12)
            .frame(height: 40)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.13))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        }
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            // 40pt of visible height plus the bar's own 6pt vertical padding
            // clears 44 without the bar looking chunky.
            .contentShape(Capsule(style: .continuous))
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
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel("\(item.title) tab. Double tap to show all tabs.")
    }
}

/// Press feedback on touch-down, not on release — the interface should
/// acknowledge the finger before it knows what the finger wants.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 1.0), value: configuration.isPressed)
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

    func body(content: Content) -> some View {
        content
            .onAppear { chrome?.beginHiding() }
            .onDisappear { chrome?.endHiding() }
    }
}

extension View {
    /// Apply to any pushed screen with its own pinned bottom action bar.
    func hidesFloatingTabBar() -> some View {
        modifier(HidesFloatingTabBar())
    }
}
