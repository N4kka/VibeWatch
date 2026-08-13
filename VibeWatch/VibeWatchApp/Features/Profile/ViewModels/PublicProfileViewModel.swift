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
    /// Moderazione M2: vero se ESISTE una riga attiva di `user_blocks` verso questo profilo.
    /// In pratica diventa vero solo bloccando da questa schermata: un profilo già bloccato il
    /// server non lo fa nemmeno caricare (`get_public_profile` → notFound, per scelta).
    @Published private(set) var isBlocked = false
    @Published private(set) var isTogglingBlock = false

    let username: String

    /// L'id della lapide su cui lavora lo sblocco (il DELETE di `apply_mutations` è per id
    /// riga). Lo conosce solo il server: si memorizza qui quando lo si incontra.
    private var blockRowId: String?

    private let load: (String) async throws -> PublicProfileDetail?
    private let follow: (String) async throws -> Void
    private let unfollow: (String) async throws -> Void
    private let loadLists: (String) async throws -> [PublicList]
    private let followList: (String) async throws -> Void
    private let unfollowList: (String) async throws -> Void
    private let currentUserId: @MainActor () -> String?
    private let blockUser: (String) async throws -> Void
    private let unblockUser: (String) async throws -> Void
    private let fetchBlockId: (String) async throws -> String?

    init(username: String,
         load: ((String) async throws -> PublicProfileDetail?)? = nil,
         follow: ((String) async throws -> Void)? = nil,
         unfollow: ((String) async throws -> Void)? = nil,
         loadLists: ((String) async throws -> [PublicList])? = nil,
         followList: ((String) async throws -> Void)? = nil,
         unfollowList: ((String) async throws -> Void)? = nil,
         currentUserId: (@MainActor () -> String?)? = nil,
         blockUser: ((String) async throws -> Void)? = nil,
         unblockUser: ((String) async throws -> Void)? = nil,
         fetchBlockId: ((String) async throws -> String?)? = nil) {
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
        self.blockUser = blockUser ?? { try await SupabaseService.shared.blockUser(userId: $0) }
        self.unblockUser = unblockUser ?? { try await ListManager.shared.unblockUser(blockId: $0) }
        self.fetchBlockId = fetchBlockId ?? {
            try await SupabaseService.shared.activeBlockId(against: $0)
        }
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

    /// Il menu "…" esiste solo su un profilo carico e altrui: bloccare sé stessi morirebbe sul
    /// CHECK del server come rifiuto muto — stessa lezione del pulsante segui.
    var canModerate: Bool {
        guard case .loaded = phase else { return false }
        return !isOwnProfile
    }

    func loadProfile() async {
        do {
            if let detail = try await load(username) {
                phase = .loaded(detail)
                // Best effort: un profilo bloccato di norma non arriva fin qui (il server lo
                // nasconde), quindi un errore su questa lettura non deve costare la schermata —
                // al massimo il menu dirà "Blocca" a chi ha già bloccato, e il server riuserà
                // la lapide senza duplicarla.
                blockRowId = try? await fetchBlockId(detail.profile.id)
                isBlocked = blockRowId != nil
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

    /// Blocca: RPC `block_user` (lapide riusata, follow potati dal trigger, tutto lato server).
    ///
    /// Ritorna l'esito perché toast e dismiss sono affari della view: qui NON si rilegge il
    /// profilo apposta — dopo il blocco il server risponderebbe notFound e la schermata
    /// sparirebbe sotto il dito prima del toast.
    func blockProfile() async -> Bool {
        guard case .loaded(let detail) = phase, !isTogglingBlock, !isOwnProfile else {
            return false
        }
        isTogglingBlock = true
        defer { isTogglingBlock = false }
        do {
            try await blockUser(detail.profile.id)
            // L'id della lapide serve solo a un eventuale sblocco da questa stessa schermata:
            // se il recupero fallisce, blockProfile resta riuscito e lo sblocco lo richiederà.
            blockRowId = try? await fetchBlockId(detail.profile.id)
            isBlocked = true
            return true
        } catch {
            return false
        }
    }

    /// Sblocca: soft delete client-synced della lapide (via outbox, `ListManager.unblockUser`).
    /// I follow NON tornano: rifolloware è una scelta, non un ripristino — come sul server.
    func unblockProfile() async -> Bool {
        guard case .loaded(let detail) = phase, !isTogglingBlock, isBlocked else { return false }
        isTogglingBlock = true
        defer { isTogglingBlock = false }
        do {
            // L'id può mancare (recupero fallito dopo il blocco): lo si richiede, e se il
            // server dice che la lapide attiva non c'è più lo sblocco è già vero.
            let rowId: String?
            if let cached = blockRowId {
                rowId = cached
            } else {
                rowId = try await fetchBlockId(detail.profile.id)
            }
            if let rowId {
                try await unblockUser(rowId)
            }
            blockRowId = nil
            isBlocked = false
            return true
        } catch {
            return false
        }
    }
}
