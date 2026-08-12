import SwiftUI

/// I tre segmenti del tab Social. `following` e `community` sono i due scope del feed
/// attività; `lists` incapsula il feed delle liste pubbliche già esistente.
enum SocialSegment: String, CaseIterable {
    case following
    case community
    case lists

    var localizationKey: String { "social.segment.\(rawValue)" }

    var feedScope: ActivityFeedScope? {
        switch self {
        case .following: return .following
        case .community: return .community
        case .lists: return nil
        }
    }
}

/// Redesign 2.0 — il quinto spazio: Social come tab, non come stanza nascosta nel profilo.
///
/// La promessa del vecchio commento è mantenuta: il feed di attività ha finalmente la sua
/// sorgente server (`get_activity_feed`) e abita qui, accanto alle liste pubbliche e alla
/// ricerca utenti. Tre segmenti: chi seguo, la community, le liste. Il feed richiede la
/// sessione (la RPC è autenticata) e le attività di un utente compaiono agli altri solo dopo
/// che ha risposto all'annuncio una tantum (`FeedAnnouncementView`) — le proprie card si
/// vedono comunque.
struct SocialView: View {
    @State private var showUserSearch = false
    /// Redesign 2.0: l'header globale è persistente su ogni tab (prototipo).
    @EnvironmentObject var appState: AppState
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var showSearch = false
    @State private var showProfile = false

    @State private var selectedSegment: SocialSegment = .following
    @State private var showAuthGate = false
    @State private var showAnnouncement = false

    /// "Ha già risposto all'annuncio": la verità sta sul profilo (`feed_activated_at`, arriva
    /// col pull), questo flag è la guardia locale che evita di ripresentare la domanda in
    /// sessione prima che il pull abbia riportato il timbro dal server.
    @AppStorage("social.feedAnnouncement.answered") private var announcementAnswered = false

    var body: some View {
        VStack(spacing: 0) {
            OfflineBanner()

            AppHeaderView(
                onSearchTap: { showSearch = true },
                onProfileTap: { showProfile = true },
                avatarURL: appState.currentUser?.avatarURL
            )

            ScreenTitleHeader(
                title: "tab.social".localized,
                subtitle: "social.subtitle".localized,
                trailingIcon: "person.badge.plus",
                onTrailingTap: { showUserSearch = true }
            )

            SegmentedPicker(
                items: SocialSegment.allCases,
                selection: $selectedSegment,
                label: { $0.localizationKey.localized }
            )
            .padding(.bottom, 16)

            content
        }
        .background(Color.theme.background.ignoresSafeArea())
        .sheet(isPresented: $showUserSearch) {
            UserSearchView()
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView(viewModel: searchViewModel)
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
        }
        // Non liquidabile con lo swipe: è una domanda, non un avviso — si risponde o si
        // chiude con la X (e in quel caso la domanda resta aperta per la prossima visita).
        .sheet(isPresented: $showAnnouncement) {
            FeedAnnouncementView(
                onAnswered: {
                    announcementAnswered = true
                    showAnnouncement = false
                },
                onClose: { showAnnouncement = false }
            )
            .interactiveDismissDisabled()
        }
        .task(id: appState.isAuthenticated) {
            await presentAnnouncementIfNeeded()
        }
    }

    // MARK: - Contenuto per segmento

    @ViewBuilder
    private var content: some View {
        switch selectedSegment {
        case .lists:
            // Il feed delle liste pubbliche: ricerca, Esplora/Seguite, follow ottimistico.
            // È lo stesso componente che viveva nel tab Liste — qui, intatto.
            PublicListsView()
        case .following, .community:
            if appState.isAuthenticated, let scope = selectedSegment.feedScope {
                ActivityFeedView(scope: scope)
                    // `id` per scope: cambiare segmento deve cambiare feed, non riciclare
                    // lo StateObject dell'altro scope con le card sbagliate dentro.
                    .id(selectedSegment)
            } else {
                // La RPC del feed è autenticata: agli anonimi si spiega e si offre la porta,
                // non si mostra un feed che non potrà mai caricarsi.
                anonymousGate
            }
        }
    }

    private var anonymousGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 56))
                .foregroundColor(.theme.textSecondary)

            Text("social.feed.gate.message".localized)
                .font(.system(size: 15))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button { showAuthGate = true } label: {
                Text("social.feed.gate.cta".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.theme.accentOrange)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Annuncio una tantum

    /// Presenta l'annuncio alla prima visita autenticata senza risposta registrata. L'ordine
    /// dei controlli è dal più economico al più costoso: flag locale, poi lo specchio
    /// `profiles` (che il pull tiene aggiornato con `feed_activated_at`).
    private func presentAnnouncementIfNeeded() async {
        guard appState.isAuthenticated, !announcementAnswered, !showAnnouncement else { return }

        guard let userId = SupabaseService.shared.currentUser?.id else { return }
        let rows = (try? await SQLiteService.shared.queryRaw(
            "SELECT feed_activated_at FROM profiles WHERE id = ?",
            parameters: [userId])) ?? []

        if let stamp = rows.first?["feed_activated_at"] as? String, !stamp.isEmpty {
            // Ha già risposto da un altro device (o prima di un reinstall): niente replica.
            announcementAnswered = true
            return
        }
        showAnnouncement = true
    }
}
