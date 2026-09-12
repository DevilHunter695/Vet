import SwiftUI

/// A lightweight, dependency-free confetti burst for genuine celebration
/// moments (booking confirmed, review submitted) — not overused, since a
/// design that celebrates everything celebrates nothing.
struct ConfettiView: View {
    @State private var pieces: [Piece] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let colors: [Color] = [Theme.accent, Theme.primary, .yellow, .green, .pink]

    struct Piece: Identifiable {
        let id = UUID()
        var x: CGFloat
        var delay: Double
        var duration: Double
        var rotation: Double
        var color: Color
        var size: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    ConfettiPiece(piece: piece, containerHeight: geo.size.height)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                pieces = (0..<24).map { _ in
                    Piece(
                        x: CGFloat.random(in: 0...geo.size.width),
                        delay: Double.random(in: 0...0.3),
                        duration: Double.random(in: 1.1...1.8),
                        rotation: Double.random(in: 0...360),
                        color: colors.randomElement()!,
                        size: CGFloat.random(in: 6...11)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: View {
    let piece: ConfettiView.Piece
    let containerHeight: CGFloat

    @State private var fallen = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(piece.color)
            .frame(width: piece.size, height: piece.size * 0.4)
            .rotationEffect(.degrees(fallen ? piece.rotation + 180 : piece.rotation))
            .position(x: piece.x, y: fallen ? containerHeight + 20 : -20)
            .opacity(fallen ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: piece.duration).delay(piece.delay)) {
                    fallen = true
                }
            }
    }
}
