import Foundation

/// Un titolo che ricorre nella pagina community: la base della strip "Popolari questa settimana".
/// Calcolato SOLO dalle righe già scaricate — nessuna RPC dedicata, quindi niente dati inventati:
/// se nella pagina nessun titolo ricorre almeno due volte, la strip semplicemente non esiste.
struct PopularFeedTitle: Identifiable, Equatable {
    let mediaType: String
    let tmdbId: Int
    let title: String?
    let posterPath: String?
    let occurrences: Int

    var id: String { "\(mediaType)-\(tmdbId)" }
}

/// ViewModel del feed attività, sulla falsariga di `PublicListsViewModel`: stati onesti
/// (caricamento / errore / vuoto / righe), paginazione dal repository, niente placeholder finti.
/// La differenza è il cursore: keyset (occurred_at, activity_id) dell'ultima riga mostrata,
/// mai un offset — le card nuove in testa non fanno scivolare le pagine successive.
@MainActor
final class ActivityFeedViewModel: ObservableObject {
    @Published private(set) var items: [ActivityItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let scope: ActivityFeedScope

    private let repository: ActivityFeedProviding
    private let pageSize = 20
    private var canLoadMore = true

    /// Iniettabile nei test come il repository: id dell'utente in sessione, per decidere
    /// quali card sono "mie" (share) senza interrogare la rete.
    private let currentUserId: @MainActor () -> String?

    init(scope: ActivityFeedScope,
         repository: ActivityFeedProviding? = nil,
         currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }) {
        self.scope = scope
        self.repository = repository ?? ActivityFeedRepository()
        self.currentUserId = currentUserId
    }

    /// Vero solo per le card dell'utente in sessione: lì (e solo lì) compare il tasto share.
    func isOwnCard(_ item: ActivityItem) -> Bool {
        guard let uid = currentUserId() else { return false }
        return item.userId.uuidString.lowercased() == uid.lowercased()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        canLoadMore = true
        do {
            let page = try await repository.fetchFeed(scope: scope, userId: nil, before: nil, limit: pageSize)
            items = await enrichMovies(page)
            canLoadMore = page.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Sentinella di paginazione stile PublicListsView: si scatta sull'ultima card visibile.
    func loadMoreIfNeeded(current: ActivityItem) async {
        guard canLoadMore, !isLoading, current.id == items.last?.id, let last = items.last else { return }
        isLoading = true
        do {
            let next = try await repository.fetchFeed(
                scope: scope, userId: nil,
                before: (last.occurredAt, last.id), limit: pageSize)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: await enrichMovies(next.filter { !existing.contains($0.id) }))
            canLoadMore = next.count == pageSize
        } catch { /* feed parziale: silenzioso, retry allo scroll successivo */ }
        isLoading = false
    }

    // MARK: - Popolari questa settimana (solo community)

    /// Raggruppa la pagina per titolo e tiene chi compare almeno due volte. Il conteggio è
    /// dichiaratamente locale alla pagina scaricata: è "ricorre nel feed", non una classifica.
    var popularThisWeek: [PopularFeedTitle] {
        var buckets: [String: PopularFeedTitle] = [:]
        for item in items {
            guard let tmdbId = item.tmdbId, let mediaType = item.mediaType else { continue }
            let key = "\(mediaType)-\(tmdbId)"
            if let existing = buckets[key] {
                buckets[key] = PopularFeedTitle(
                    mediaType: mediaType, tmdbId: tmdbId,
                    // Il primo avvistamento può essere una riga non ancora arricchita: il
                    // titolo/poster si prende dal primo che li porta.
                    title: existing.title ?? item.title,
                    posterPath: existing.posterPath ?? item.posterPath,
                    occurrences: existing.occurrences + 1)
            } else {
                buckets[key] = PopularFeedTitle(
                    mediaType: mediaType, tmdbId: tmdbId,
                    title: item.title, posterPath: item.posterPath, occurrences: 1)
            }
        }
        return buckets.values
            .filter { $0.occurrences >= 2 && $0.posterPath != nil }
            .sorted { $0.occurrences != $1.occurrences ? $0.occurrences > $1.occurrences : $0.tmdbId < $1.tmdbId }
            .prefix(10)
            .map { $0 }
    }

    // MARK: - Arricchimento film

    /// Le righe dei film arrivano senza titolo né poster (il server non ha un catalogo film):
    /// si risolvono qui, prima dalla cache dettagli e poi da TMDB. In batch e a prova di
    /// fallimento — una card senza poster resta una card, non un errore.
    private func enrichMovies(_ page: [ActivityItem]) async -> [ActivityItem] {
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

private extension ActivityItem {
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
