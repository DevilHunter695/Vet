import SwiftUI

/// A divider for use *inside* a glass surface.
///
/// A stock `Divider()` is a hard, full-width rule, which is the right thing
/// in a system list and the wrong thing on glass: it cuts the surface in two
/// rather than reading as a seam within one pane. Real glass divisions catch
/// light in the middle and vanish where the pane curves away, so this fades
/// out at both ends.
///
/// `axis` is the direction the seam *runs*, not the direction it separates in.
struct GlassSeam: View {
    var axis: Axis = .horizontal
    /// How far in from each end the seam is fully faded, as a fraction.
    var inset: CGFloat = 8
    var strength: Double = 0.16

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.0), location: 0.0),
                .init(color: .white.opacity(strength), location: 0.5),
                .init(color: .white.opacity(0.0), location: 1.0)
            ],
            startPoint: axis == .horizontal ? .leading : .top,
            endPoint: axis == .horizontal ? .trailing : .bottom
        )
    }

    var body: some View {
        gradient
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
            .accessibilityHidden(true)
    }
}
