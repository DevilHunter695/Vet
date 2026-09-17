import SwiftUI

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
        }
        .background(alignment: .top) {
            bleed
                .frame(height: bleedHeight)
                .allowsHitTesting(false)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var poster: some View {
        if let imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    fallbackPoster
                default:
                    // Not a spinner: a spinner on a 260pt block is a flashing
                    // hole in the layout. The brand surface is already the
                    // right shape, so the photograph simply arrives into it.
                    fallbackPoster
                }
            }
        } else {
            fallbackPoster
        }
    }

    private var fallbackPoster: some View {
        ZStack {
            IdentityPalette.poster(for: seed)
            // Oversized and cropped by the poster's own bounds, so it reads
            // as artwork rather than as a placeholder icon centred in a box.
            Image(systemName: fallbackSymbol)
                .font(.system(size: 150, weight: .semibold))
                .foregroundStyle(.white.opacity(0.16))
                .offset(x: 70, y: 40)
            Image(systemName: fallbackSymbol)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
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
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 70, opaque: true)
                            .opacity(0.5)
                    } else {
                        colourBleed
                    }
                }
            } else {
                colourBleed
            }
        }
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
