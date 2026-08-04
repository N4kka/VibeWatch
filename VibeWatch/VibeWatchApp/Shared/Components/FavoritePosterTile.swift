import SwiftUI

/// Da dove arriva il poster di un preferito, in ordine di costo.
///
/// Ogni tile faceva una chiamata TMDB di dettaglio, e quelle chiamate passano dal serializzatore
/// condiviso con caroselli e prefetch: con la coda piena i poster comparivano minuti dopo e la
/// vetrina restava una fila di segnaposto grigi. Un preferito però è quasi sempre un titolo già
/// aperto o già in una lista: il dato è di solito già sul telefono.
struct FavoritePosterResolver {
    /// La cache dei dettagli (`detail_cache`): c'è per ogni titolo aperto almeno una volta.
    var cachedPosterPath: (_ mediaType: String, _ tmdbId: Int) async -> String?
    /// Lo specchio locale delle liste e del tracking.
    var storedPosterPath: (_ mediaType: String, _ tmdbId: Int) async -> String?
    /// L'ultima spiaggia: una chiamata di rete.
    var remotePosterPath: (_ mediaType: String, _ tmdbId: Int) async -> String?

    func posterPath(mediaType: String, tmdbId: Int) async -> String? {
        if let path = await cachedPosterPath(mediaType, tmdbId) { return path }
        if let path = await storedPosterPath(mediaType, tmdbId) { return path }
        return await remotePosterPath(mediaType, tmdbId)
    }

    func posterURL(mediaType: String, tmdbId: Int) async -> URL? {
        guard let path = await posterPath(mediaType: mediaType, tmdbId: tmdbId), !path.isEmpty else {
            return nil
        }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }
}

@MainActor
private enum FavoritePosterSources {
    static func cached(_ mediaType: String, _ tmdbId: Int) async -> String? {
        if mediaType == MediaType.movie.rawValue {
            let cached = (try? await DetailCacheService.shared.getCachedMovieDetails(movieId: tmdbId)) ?? nil
            return cached?.movie.posterPath
        }
        let cached = (try? await DetailCacheService.shared.getCachedTVShowDetails(tvShowId: tmdbId)) ?? nil
        return cached?.tvShow.posterPath
    }

    static func stored(_ mediaType: String, _ tmdbId: Int) async -> String? {
        let rows = (try? await SQLiteService.shared.queryRaw(
            """
            SELECT poster_path FROM list_items
             WHERE media_id = ? AND media_type = ? AND deleted_at IS NULL
               AND poster_path IS NOT NULL AND poster_path <> ''
             LIMIT 1
            """,
            parameters: [tmdbId, mediaType]
        )) ?? []
        if let path = rows.first?["poster_path"] as? String, !path.isEmpty { return path }

        guard mediaType != MediaType.movie.rawValue else { return nil }
        let tracking = (try? await SQLiteService.shared.queryRaw(
            """
            SELECT show_poster_path FROM tv_tracking
             WHERE tmdb_show_id = ? AND show_poster_path IS NOT NULL AND show_poster_path <> ''
             LIMIT 1
            """,
            parameters: [tmdbId]
        )) ?? []
        return tracking.first?["show_poster_path"] as? String
    }

    static func remote(_ mediaType: String, _ tmdbId: Int) async -> String? {
        if mediaType == MediaType.movie.rawValue {
            return try? await TMDBService.shared.getMovieDetails(id: tmdbId).posterPath
        }
        return try? await TMDBService.shared.getTVShowDetails(id: tmdbId).posterPath
    }
}

extension FavoritePosterResolver {
    static let live = FavoritePosterResolver(
        cachedPosterPath: { await FavoritePosterSources.cached($0, $1) },
        storedPosterPath: { await FavoritePosterSources.stored($0, $1) },
        remotePosterPath: { await FavoritePosterSources.remote($0, $1) }
    )
}

/// Un poster dei favorites di §9.3. Il profilo pubblico porta solo `tmdb_id` e slot — titoli e
/// poster sono catalogo pubblico, quindi si risolvono qui, dal client, con la cache immagini che
/// il resto dell'app già usa.
///
/// Il fallimento della risoluzione non è un errore da schermo: resta il segnaposto col numero
/// dello slot muto — un profilo altrui non deve rompersi perché TMDB non risponde.
struct FavoritePosterTile: View {
    let mediaType: String
    let tmdbId: Int
    var resolver: FavoritePosterResolver = .live

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
            Image(systemName: mediaType == MediaType.movie.rawValue ? "film" : "tv")
                .font(.system(size: 20))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
        }
    }

    private func resolvePoster() async {
        guard posterURL == nil else { return }
        posterURL = await resolver.posterURL(mediaType: mediaType, tmdbId: tmdbId)
    }
}
