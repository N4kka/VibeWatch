import SwiftUI

/// Un poster dei favorites di §9.3. Il profilo pubblico porta solo `tmdb_id` e slot — titoli e
/// poster sono catalogo pubblico, quindi si risolvono qui, dal client, con la cache immagini che
/// il resto dell'app già usa.
///
/// Il fallimento della risoluzione non è un errore da schermo: resta il segnaposto col numero
/// dello slot muto — un profilo altrui non deve rompersi perché TMDB non risponde.
struct FavoritePosterTile: View {
    let mediaType: String
    let tmdbId: Int

    @State private var posterURL: URL?

    var body: some View {
        Group {
            if let url = posterURL {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderView
                }
            } else {
                placeholderView
            }
        }
        .frame(width: 64, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await resolvePoster() }
    }

    private var placeholderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
            Image(systemName: mediaType == "movie" ? "film" : "tv")
                .font(.system(size: 20))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
        }
    }

    private func resolvePoster() async {
        guard posterURL == nil else { return }
        if mediaType == "movie" {
            posterURL = try? await TMDBService.shared.getMovieDetails(id: tmdbId).posterURL
        } else {
            posterURL = try? await TMDBService.shared.getTVShowDetails(id: tmdbId).posterURL
        }
    }
}
