import Foundation

/// Il server non ha un catalogo film (lezione di `20260802230000`): le card `movie` arrivano con
/// `title` e `poster_path` nulli e si riempiono qui, cache-first. Le serie no — quelle il loro
/// snapshot ce l'hanno da `tmdb_shows`.
///
/// Vive fuori dai ViewModel perché di posti che mostrano card ce n'è più d'uno (il feed del tab
/// Social, l'attività recente del profilo, la card singola del deep link) e una card senza poster
/// in uno solo di quei posti sarebbe un difetto invisibile in revisione: chi scrive il terzo
/// chiamante non sa che il primo faceva un lavoro in più.
enum ActivityMovieEnricher {

    /// Riempie i buchi delle righe `movie`. In batch, e a prova di fallimento: un titolo che non
    /// si risolve resta una card col suo ripiego, non un errore che ferma la pagina.
    static func enrich(_ page: [ActivityItem]) async -> [ActivityItem] {
        let missingIds = Set(page.compactMap { item -> Int? in
            guard item.mediaType == "movie", let tmdbId = item.tmdbId,
                  item.title == nil || item.posterPath == nil else { return nil }
            return tmdbId
        })
        guard !missingIds.isEmpty else { return page }

        var resolved: [Int: (title: String, posterPath: String?)] = [:]
        await withTaskGroup(of: (Int, (title: String, posterPath: String?)?).self) { group in
            for movieId in missingIds {
                group.addTask {
                    // Cache-first: se il dettaglio è già passato di qui, zero rete.
                    if let cached = try? await DetailCacheService.shared.getCachedMovieDetails(movieId: movieId) {
                        return (movieId, (cached.movie.title, cached.movie.posterPath))
                    }
                    if let movie = try? await TMDBService.shared.getMovieDetails(id: movieId) {
                        return (movieId, (movie.title, movie.posterPath))
                    }
                    return (movieId, nil)
                }
            }
            for await (movieId, details) in group {
                if let details { resolved[movieId] = details }
            }
        }
        guard !resolved.isEmpty else { return page }

        return page.map { item in
            guard item.mediaType == "movie", let tmdbId = item.tmdbId,
                  let details = resolved[tmdbId],
                  item.title == nil || item.posterPath == nil else { return item }
            return item.filling(title: details.title, posterPath: details.posterPath)
        }
    }
}

extension ActivityItem {
    /// Copia con titolo/poster risolti: i campi sono `let` di proposito (la riga è del server),
    /// l'arricchimento riempie solo i buchi che il server dichiara di non saper riempire.
    func filling(title newTitle: String?, posterPath newPosterPath: String?) -> ActivityItem {
        ActivityItem(
            id: id, userId: userId, username: username, displayName: displayName,
            avatarUrl: avatarUrl, activityType: activityType, mediaType: mediaType,
            tmdbId: tmdbId, episodeCount: episodeCount, rating: rating, reviewId: reviewId,
            reviewContent: reviewContent, containsSpoilers: containsSpoilers, listId: listId,
            listName: listName, listCoverPosterPaths: listCoverPosterPaths,
            title: title ?? newTitle, posterPath: posterPath ?? newPosterPath,
            occurredAt: occurredAt, likeCount: likeCount, commentCount: commentCount,
            likedByMe: likedByMe)
    }
}
