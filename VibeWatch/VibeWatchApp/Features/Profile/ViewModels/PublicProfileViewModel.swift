import Foundation

/// SPEC v3 §9.3 — il profilo di un altro utente.
///
/// I numeri (follower, following, `follows_me`) sono del server e solo del server: la RLS
/// nasconde al client i follow altrui, quindi qui non si somma niente — si chiede e si mostra.
/// L'unica scrittura è il follow/unfollow, e segue la regola del tracking: un'azione per volta,
/// stato "in volo" visibile, e alla fine si **rilegge** — una scrittura riuscita senza rilettura
/// non produce niente di visibile (§1.1, imparato con "visto" che non faceva niente).
@MainActor
final class PublicProfileViewModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded(PublicProfileDetail)
        case notFound        // include bloccato nei due versi: il server non li distingue apposta
        case failed
    }

    /// §9.3, ultimo bullet: le liste pubbliche dell'utente. Fase separata dal profilo perché
    /// arrivano da una seconda chiamata: un profilo carico con le liste in errore deve dire
    /// "liste non caricate, riprova" — non fingersi un profilo senza liste.
    enum ListsPhase: Equatable {
        case loading
        case loaded([PublicList])
        case failed
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var listsPhase: ListsPhase = .loading
    @Published private(set) var isTogglingFollow = false

    let username: String

    private let load: (String) async throws -> PublicProfileDetail?
    private let follow: (String) async throws -> Void
    private let unfollow: (String) async throws -> Void
    private let loadLists: (String) async throws -> [PublicList]
    private let followList: (String) async throws -> Void
    private let unfollowList: (String) async throws -> Void
    private let currentUserId: @MainActor () -> String?

    init(username: String,
         load: ((String) async throws -> PublicProfileDetail?)? = nil,
         follow: ((String) async throws -> Void)? = nil,
         unfollow: ((String) async throws -> Void)? = nil,
         loadLists: ((String) async throws -> [PublicList])? = nil,
         followList: ((String) async throws -> Void)? = nil,
         unfollowList: ((String) async throws -> Void)? = nil,
         currentUserId: (@MainActor () -> String?)? = nil) {
        self.username = username
        self.load = load ?? { try await SupabaseService.shared.publicProfile(username: $0) }
        self.follow = follow ?? { try await SocialActions.shared.follow(userId: $0) }
        self.unfollow = unfollow ?? { try await SocialActions.shared.unfollow(userId: $0) }
        self.loadLists = loadLists ?? { ownerId in
            try await SupabaseService.shared.fetchPublicLists(
                search: nil, scope: .explore, limit: 50, offset: 0, ownerId: ownerId)
        }
        self.followList = followList ?? { try await ListManager.shared.followList(listId: $0) }
        self.unfollowList = unfollowList ?? { try await ListManager.shared.unfollowList(listId: $0) }
        self.currentUserId = currentUserId ?? { SupabaseService.shared.currentUser?.id }
    }

    /// Il proprio profilo si può guardare — "come appaio?" merita risposta — ma non seguire.
    ///
    /// Trovato sul dispositivo: il pulsante c'era anche qui, il tap partiva, il CHECK
    /// `follower <> followee` lo respingeva, e la schermata tornava com'era senza dire niente —
    /// il fallimento invisibile che invita a ripremere. Il pulsante non deve esistere.
    var isOwnProfile: Bool {
        guard case .loaded(let detail) = phase else { return false }
        return detail.profile.id == currentUserId()
    }

    func loadProfile() async {
        do {
            if let detail = try await load(username) {
                phase = .loaded(detail)
                await loadPublicLists(ownerId: detail.profile.id)
            } else {
                phase = .notFound
            }
        } catch {
            // Un errore di rete non è "questo profilo non esiste": dirlo sarebbe la stessa
            // bugia di "già preso" per un parse fallito.
            phase = .failed
        }
    }

    func loadPublicLists(ownerId: String) async {
        do {
            listsPhase = .loaded(try await loadLists(ownerId))
        } catch {
            // Un errore non è "nessuna lista": la sezione mostra la riprova, non il vuoto.
            listsPhase = .failed
        }
    }

    func retryLists() async {
        guard case .loaded(let detail) = phase else { return }
        listsPhase = .loading
        await loadPublicLists(ownerId: detail.profile.id)
    }

    /// Segui/smetti su una lista del profilo: ottimistico con rollback, come nel feed
    /// (`PublicListsViewModel.toggleFollow`) — un tap che non cambia niente a schermo
    /// invita a ripremere.
    func toggleListFollow(_ list: PublicList) async {
        guard case .loaded(var lists) = listsPhase,
              let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        let wasFollowing = lists[idx].isFollowing
        lists[idx].isFollowing.toggle()
        listsPhase = .loaded(lists)
        do {
            if wasFollowing {
                try await unfollowList(list.id)
            } else {
                try await followList(list.id)
            }
        } catch {
            if case .loaded(var current) = listsPhase,
               let i = current.firstIndex(where: { $0.id == list.id }) {
                current[i].isFollowing = wasFollowing
                listsPhase = .loaded(current)
            }
        }
    }

    func toggleFollow() async {
        guard case .loaded(let detail) = phase, !isTogglingFollow, !isOwnProfile else { return }
        isTogglingFollow = true
        defer { isTogglingFollow = false }

        do {
            if detail.isFollowing {
                try await unfollow(detail.profile.id)
            } else {
                try await follow(detail.profile.id)
            }
            // La rilettura è la metà che si dimentica: i contatori li fa il server.
            await loadProfile()
        } catch {
            // La scrittura è fallita: lo stato resta quello vero, e ricaricare lo conferma.
            await loadProfile()
        }
    }
}
