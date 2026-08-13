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

/// La sola porta del ViewModel verso le interazioni: il toggle del like. Protocollo minimo
/// (come `ActivityFeedProviding`) per testare l'ottimismo e il rollback senza rete né SQLite.
@MainActor
protocol ActivityLikeToggling {
    func toggleActivityLike(activityId: UUID) async throws -> (liked: Bool, likeCount: Int)
}

extension ActivityInteractionService: ActivityLikeToggling {}

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
    private let interactions: ActivityLikeToggling
    private let pageSize = 20
    private var canLoadMore = true

    /// Un toggle per card alla volta: il secondo tap durante il volo del primo non parte —
    /// due toggle in corsa si annullerebbero a vicenda sul server.
    private var likesInFlight: Set<UUID> = []

    /// Iniettabile nei test come il repository: id dell'utente in sessione, per decidere
    /// quali card sono "mie" (share) senza interrogare la rete.
    private let currentUserId: @MainActor () -> String?

    init(scope: ActivityFeedScope,
         repository: ActivityFeedProviding? = nil,
         interactions: ActivityLikeToggling? = nil,
         currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }) {
        self.scope = scope
        self.repository = repository ?? ActivityFeedRepository()
        self.interactions = interactions ?? ActivityInteractionService.shared
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

    // MARK: - Interazioni (M2)

    /// Toggle del like con ottimismo e riconciliazione: la card cambia SUBITO, poi la risposta
    /// del server — (liked, like_count) veri — sovrascrive la stima. Al fallimento si torna
    /// alla riga di prima e lo si dice con un toast: MAI un retry cieco, un toggle ritentato
    /// alla cieca inverte l'intento invece di confermarlo.
    func toggleLike(for item: ActivityItem) async {
        guard !likesInFlight.contains(item.id),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        likesInFlight.insert(item.id)
        defer { likesInFlight.remove(item.id) }

        let original = items[index]
        items[index] = original.updating(
            likeCount: max(0, original.likeCount + (original.likedByMe ? -1 : 1)),
            likedByMe: !original.likedByMe)

        do {
            let result = try await interactions.toggleActivityLike(activityId: item.id)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = items[idx].updating(
                    likeCount: result.likeCount, likedByMe: result.liked)
            }
            AnalyticsService.shared.track(.activityLiked(
                activityType: item.activityType.rawValue, added: result.liked))
        } catch {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = original
            }
            ToastCenter.shared.show(
                error: ActivityInteractionService.isContentUnavailable(error)
                    ? "social.comments.unavailable".localized
                    : "social.error.likeFailed".localized)
        }
    }

    // MARK: - Rimuovi dal feed (M3)

    /// Toglie una PROPRIA card dal feed. La riga sparisce subito e torna al suo posto se il
    /// server dice di no: l'inverso (aspettare la risposta con la card ancora lì) farebbe
    /// sembrare che il gesto non abbia funzionato, e il secondo tap arriverebbe comunque.
    ///
    /// L'ordine di prima si conserva con l'indice: reinserire in coda sposterebbe una card
    /// vecchia in cima al feed, che è un secondo errore sopra al primo.
    func hide(_ item: ActivityItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)

        do {
            let hidden = try await repository.hideActivity(id: item.id)
            if hidden {
                AnalyticsService.shared.track(.activityHidden(activityType: item.activityType.rawValue))
                ToastCenter.shared.show(success: "social.hide.done".localized)
            } else {
                // Il server non l'ha nascosta (non è nostra, o non esiste più): rimetterla dov'era
                // è l'unica risposta onesta — sparire lo stesso fingerebbe un esito mai avvenuto.
                items.insert(removed, at: min(index, items.count))
                ToastCenter.shared.show(error: "social.hide.failed".localized)
            }
        } catch {
            items.insert(removed, at: min(index, items.count))
            ToastCenter.shared.show(error: "social.hide.failed".localized)
        }
    }

    /// L'aggancio del foglio commenti: alla chiusura (o a ogni post/delete) il conteggio della
    /// card si riallinea senza rifare la pagina del feed.
    func setCommentCount(_ count: Int, for activityId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == activityId }) else { return }
        items[index] = items[index].updating(commentCount: max(0, count))
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

    /// Le righe dei film arrivano senza titolo né poster: le riempie `ActivityMovieEnricher`,
    /// che è condiviso con l'attività recente del profilo — un solo posto che sa come si fa.
    private func enrichMovies(_ page: [ActivityItem]) async -> [ActivityItem] {
        await ActivityMovieEnricher.enrich(page)
    }
}

private extension ActivityItem {
    /// Copia con i contatori sociali aggiornati — l'unica parte della riga che il client ha
    /// il diritto di toccare, e solo per specchiare ciò che il server ha già deciso (o sta
    /// per decidere, nell'attimo ottimistico prima della riconciliazione).
    func updating(likeCount newLikeCount: Int? = nil,
                  likedByMe newLikedByMe: Bool? = nil,
                  commentCount newCommentCount: Int? = nil) -> ActivityItem {
        ActivityItem(
            id: id, userId: userId, username: username, displayName: displayName,
            avatarUrl: avatarUrl, activityType: activityType, mediaType: mediaType,
            tmdbId: tmdbId, episodeCount: episodeCount, rating: rating, reviewId: reviewId,
            reviewContent: reviewContent, containsSpoilers: containsSpoilers, listId: listId,
            listName: listName, listCoverPosterPaths: listCoverPosterPaths,
            title: title, posterPath: posterPath,
            occurredAt: occurredAt,
            likeCount: newLikeCount ?? likeCount,
            commentCount: newCommentCount ?? commentCount,
            likedByMe: newLikedByMe ?? likedByMe)
    }
}
