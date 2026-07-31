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

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isTogglingFollow = false

    let username: String

    private let load: (String) async throws -> PublicProfileDetail?
    private let follow: (String) async throws -> Void
    private let unfollow: (String) async throws -> Void
    private let currentUserId: @MainActor () -> String?

    init(username: String,
         load: ((String) async throws -> PublicProfileDetail?)? = nil,
         follow: ((String) async throws -> Void)? = nil,
         unfollow: ((String) async throws -> Void)? = nil,
         currentUserId: (@MainActor () -> String?)? = nil) {
        self.username = username
        self.load = load ?? { try await SupabaseService.shared.publicProfile(username: $0) }
        self.follow = follow ?? { try await SocialActions.shared.follow(userId: $0) }
        self.unfollow = unfollow ?? { try await SocialActions.shared.unfollow(userId: $0) }
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
            } else {
                phase = .notFound
            }
        } catch {
            // Un errore di rete non è "questo profilo non esiste": dirlo sarebbe la stessa
            // bugia di "già preso" per un parse fallito.
            phase = .failed
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
