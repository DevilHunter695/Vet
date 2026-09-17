import SwiftUI

/// The cart affordance that sits in the top-right of every catalog screen.
///
/// The previous version was a bare `NavigationLink { CartView() } label: {
/// Image(systemName: "cart") }`. Two things were wrong with it:
///
///  1. It inherited whatever tint the navigation bar happened to resolve, and
///     against the dark aurora bar that lands on a low-contrast system grey —
///     it read as a disabled control rather than the primary way back to
///     checkout.
///  2. A bare glyph in a toolbar has roughly a 24pt hit target, which is the
///     single most-missed tap in the app.
///
/// So: an explicit brand tint, a 44pt target, and a live count badge so the
/// customer can tell at a glance whether anything is actually in there.
struct CartToolbarButton: View {
    @Environment(SessionStore.self) private var session
    @State private var itemCount = 0

    private let manageCartUseCase = DependencyContainer.shared.manageCartUseCase()

    var body: some View {
        NavigationLink {
            CartView()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: itemCount > 0 ? "cart.fill" : "cart")
                    .scaledIcon(17, weight: .semibold)
                    .foregroundStyle(Theme.primaryLight)
                    .frame(width: 44, height: 44)

                if itemCount > 0 {
                    Text("\(itemCount)")
                        .font(.caption2.bold())
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: -4, y: 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(itemCount > 0 ? "Cart, \(itemCount) items" : "Cart, empty")
        .task { await refresh() }
    }

    private func refresh() async {
        guard let userId = session.currentUser?.id else { return }
        itemCount = (try? await manageCartUseCase.current(userId: userId))?.items.reduce(0) { $0 + $1.quantity } ?? 0
    }
}
