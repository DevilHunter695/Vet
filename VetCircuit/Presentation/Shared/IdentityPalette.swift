import SwiftUI

/// A stable colour derived from a string.
///
/// Luma's screens each carry their own colour because each has its own
/// poster. Most records in this app have no photograph, so without something
/// standing in, every detail screen would be the same brand gradient and the
/// idea would be lost. Deriving the hue from the record's identity keeps the
/// effect that matters — one vet's screen does not look like another's — and
/// it costs nothing and never fails to load.
enum IdentityPalette {
    /// FNV-1a, not `hashValue`.
    ///
    /// Swift seeds `Hashable` per process, so the same name would produce a
    /// different colour on every launch — the screen would change colour
    /// between runs, which is exactly the kind of thing that reads as a bug.
    /// This is deterministic forever.
    private static func hash(_ string: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }

    /// Hues are picked off a curated wheel rather than the full 360°, because
    /// the raw wheel includes bands — muddy yellow-greens, and anything close
    /// to the red used for destructive actions — that either look ill or
    /// carry a meaning this must not borrow.
    private static let hues: [Double] = [
        0.58,  // brand blue
        0.52,  // teal
        0.44,  // sea green
        0.78,  // violet
        0.86,  // magenta
        0.09,  // amber
        0.63,  // indigo
        0.36   // moss
    ]

    static func hue(for seed: String) -> Double {
        hues[Int(hash(seed) % UInt64(hues.count))]
    }

    /// The poster fill: deep enough that white type sits on it comfortably,
    /// saturated enough to actually read as a colour.
    static func poster(for seed: String) -> LinearGradient {
        let h = hue(for: seed)
        return LinearGradient(
            colors: [
                Color(hue: h, saturation: 0.62, brightness: 0.46),
                Color(hue: (h + 0.06).truncatingRemainder(dividingBy: 1.0), saturation: 0.74, brightness: 0.22)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// The wash that bleeds behind the header and colours the screen.
    static func accent(for seed: String) -> Color {
        Color(hue: hue(for: seed), saturation: 0.66, brightness: 0.52)
    }
}
