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

    /// HSB "brightness" is not perceived brightness: a warm, yellow-leaning
    /// hue like the amber entry above reads noticeably lighter than a blue
    /// at the identical brightness value, because yellow itself carries far
    /// more luminance than blue does. Left at the same 0.46, amber's white
    /// overlay content sits at roughly a 2.6:1 contrast ratio — under even
    /// the 3:1 floor for large text. Pull just that warm band down so every
    /// hue on the wheel clears it.
    private static func posterTopBrightness(for hue: Double) -> Double {
        (0.02...0.16).contains(hue) ? 0.34 : 0.46
    }

    /// The poster fill: deep enough that white type sits on it comfortably,
    /// saturated enough to actually read as a colour.
    static func poster(for seed: String) -> LinearGradient {
        let h = hue(for: seed)
        let topBrightness = posterTopBrightness(for: h)
        return LinearGradient(
            colors: [
                Color(hue: h, saturation: 0.62, brightness: topBrightness),
                Color(
                    hue: (h + 0.06).truncatingRemainder(dividingBy: 1.0),
                    saturation: 0.74,
                    // Keeps the same ~2:1 ratio between the two stops that
                    // the original 0.46 → 0.22 pairing had.
                    brightness: topBrightness * (0.22 / 0.46)
                )
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// The wash that bleeds behind the header and colours the screen.
    static func accent(for seed: String) -> Color {
        Color(hue: hue(for: seed), saturation: 0.66, brightness: 0.52)
    }
}
