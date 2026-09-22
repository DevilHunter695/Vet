import SwiftUI
import UIKit
import ImageIO

/// Luma's image-led detail header.
///
/// The idea worth stealing is not the layout, it is where the colour comes
/// from: Luma's event screens take their mood from *their own poster* — the
/// eclipse screen is warm because its poster is, the shelter-dogs screen is
/// deep green because its flyer is. The background is the same image blown up
/// and blurred behind the content, so every screen is coloured by what is
/// actually on it rather than by one brand gradient applied everywhere.
///
/// That is also why this needs no colour extraction: the image *is* the
/// palette. One `AsyncImage` load serves both the poster and the bleed.
struct PosterHeader<Overlay: View>: View {
    let imageURL: URL?
    /// Drawn on the record's own colour when there is no photograph, so the
    /// header keeps its shape and the screen keeps a colour of its own.
    let fallbackSymbol: String
    /// What the fallback colour is derived from — a name or an id. Stable
    /// input, stable colour: see `IdentityPalette`.
    let seed: String
    let title: String
    var subtitle: String?
    @ViewBuilder var overlay: Overlay

    private let posterHeight: CGFloat = 260
    private let bleedHeight: CGFloat = 460

    // One fetch feeds both the poster and the bleed, decoded once into two
    // sizes (see `decode(data:)`). Two independent `AsyncImage`s hitting the
    // same URL usually converge thanks to `URLCache`, but "usually" is how a
    // poster ends up with no matching bleed the one time the cache is cold
    // and the two requests race — this makes that impossible by construction.
    @State private var posterImage: Image?
    @State private var bleedImage: Image?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            poster
                .frame(height: posterHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    // The same top-lit rim every other surface in the app
                    // carries, so a photograph still reads as a pane of the
                    // same material rather than a sticker dropped on top.
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .brandDisplayText()
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(.brandCallout)
                        .foregroundStyle(Theme.textSecondary)
                }

                overlay
            }
            .accessibilityElement(children: .combine)
        }
        .background(alignment: .top) {
            bleed
                .frame(height: bleedHeight)
                .allowsHitTesting(false)
        }
        .task(id: imageURL) { await load() }
    }

    /// Fetches the URL once and decodes it into the two sizes the poster and
    /// the bleed actually need, instead of asking two `AsyncImage`s to each
    /// fetch and decode the full-resolution photograph independently. That
    /// also means the 460pt bleed is never blurring a full-size source.
    private func load() async {
        posterImage = nil
        bleedImage = nil
        guard let imageURL else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            guard let decoded = await Task.detached(priority: .userInitiated, operation: {
                Self.decode(data: data)
            }).value else { return }
            if Task.isCancelled { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                posterImage = decoded.poster
                bleedImage = decoded.bleed
            }
        } catch {
            // Cancellation (e.g. the URL changed) and genuine failures both
            // land here; either way the identity-coloured fallback already
            // on screen is the right thing to keep showing.
        }
    }

    /// Decodes the poster at display size and the bleed at a small size the
    /// heavy blur will erase the detail of anyway — cheaper to decode, and
    /// far cheaper to blur and to keep resident while the header scrolls.
    private nonisolated static func decode(data: Data) -> (poster: Image, bleed: Image)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let posterOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        let bleedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard
            let posterCG = CGImageSourceCreateThumbnailAtIndex(source, 0, posterOptions as CFDictionary),
            let bleedCG = CGImageSourceCreateThumbnailAtIndex(source, 0, bleedOptions as CFDictionary)
        else { return nil }
        return (
            Image(uiImage: UIImage(cgImage: posterCG)),
            Image(uiImage: UIImage(cgImage: bleedCG))
        )
    }

    // MARK: Pieces

    @ViewBuilder
    private var poster: some View {
        ZStack {
            // The fallback stays mounted underneath and crossfades out, so
            // the swap reads as the photograph arriving rather than an
            // instant pop from one flat colour to another.
            fallbackPoster
                .opacity(posterImage == nil ? 1 : 0)
            if let posterImage {
                posterImage
                    .resizable()
                    .scaledToFill()
                    .transition(reduceMotion ? .identity : .opacity)
                    // Decorative: the title and subtitle already say what
                    // this record is, so VoiceOver does not need to visit an
                    // image with nothing more to tell it.
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: posterImage == nil)
    }

    private var fallbackPoster: some View {
        ZStack {
            IdentityPalette.poster(for: seed)
            // Oversized and cropped by the poster's own bounds, so it reads
            // as artwork rather than as a placeholder icon centred in a box.
            Image(systemName: fallbackSymbol)
                // Pinned deliberately. This pair is artwork: a 150pt
                // watermark offset behind a 56pt symbol. Scaling either
                // with the text setting pulls the composition apart, and
                // neither carries information the header does not also say
                // in type that does scale.
                .font(.system(size: 150, weight: .semibold))
                .foregroundStyle(.white.opacity(0.16))
                .offset(x: 70, y: 40)
            Image(systemName: fallbackSymbol)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        // Purely decorative brand fill — the record's title already carries
        // the meaning, so this should not read as an unlabeled image.
        .accessibilityHidden(true)
    }

    /// The image again, huge and blurred, fading out downward — this is what
    /// tints the whole screen.
    private var bleedMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black.opacity(0.55), location: 0.45),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    @ViewBuilder
    private var bleed: some View {
        Group {
            if let bleedImage {
                bleedImage
                    .resizable()
                    .scaledToFill()
                    // A ~160px source blurred at radius 70 loses no visible
                    // detail versus blurring the full-resolution photograph
                    // — the blur destroys that detail either way — but is far
                    // cheaper to keep rasterised while this scrolls.
                    .blur(radius: 70, opaque: true)
                    .opacity(0.5)
                    .accessibilityHidden(true)
            } else {
                colourBleed
            }
        }
        // Flattens the blur + gradient mask into one bitmap instead of
        // recompositing them every frame the scroll view moves this layer.
        .drawingGroup()
        .mask { bleedMask }
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    /// The no-photograph wash: the record's own hue, soft and off-centre, so
    /// the screen still takes a colour from what is on it.
    private var colourBleed: some View {
        IdentityPalette.accent(for: seed)
            .opacity(0.42)
            .blur(radius: 60)
    }
}

extension PosterHeader where Overlay == EmptyView {
    init(imageURL: URL?, fallbackSymbol: String, seed: String, title: String, subtitle: String? = nil) {
        self.init(
            imageURL: imageURL,
            fallbackSymbol: fallbackSymbol,
            seed: seed,
            title: title,
            subtitle: subtitle,
            overlay: { EmptyView() }
        )
    }
}
