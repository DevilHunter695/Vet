import SwiftUI

/// VetCircuit's mascot: a friendly vector-drawn paw, built entirely from
/// SwiftUI shapes so it renders crisply at any size with zero image assets.
/// Used on the sign-in hero, empty states, and loading moments.
struct PawMascot: View {
    var size: CGFloat = 96
    var animated: Bool = true

    @State private var bounce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.gradient)
                .frame(width: size, height: size)
                .shadow(color: Theme.primary.opacity(0.35), radius: size * 0.12, y: size * 0.06)

            PawShape()
                .fill(.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .offset(y: bounce ? -size * 0.02 : size * 0.02)
        }
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                bounce = true
            }
        }
    }
}

/// A simple, recognizable paw print drawn as a path: one large pad plus
/// four toes, normalized to a unit square so it scales cleanly.
private struct PawShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) {
            path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }

        // Main pad
        ellipse(cx: w * 0.5, cy: h * 0.62, rx: w * 0.32, ry: h * 0.28)
        // Toes
        ellipse(cx: w * 0.20, cy: h * 0.28, rx: w * 0.15, ry: h * 0.17)
        ellipse(cx: w * 0.42, cy: h * 0.12, rx: w * 0.15, ry: h * 0.17)
        ellipse(cx: w * 0.65, cy: h * 0.12, rx: w * 0.15, ry: h * 0.17)
        ellipse(cx: w * 0.86, cy: h * 0.28, rx: w * 0.15, ry: h * 0.17)

        return path
    }
}

/// Small inline mascot mark used in navigation bars / headers.
struct MascotMark: View {
    var size: CGFloat = 28

    var body: some View {
        PawMascot(size: size, animated: false)
    }
}

#Preview {
    VStack(spacing: 24) {
        PawMascot(size: 120)
        MascotMark()
    }
    .padding()
}
