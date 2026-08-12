import SwiftUI

/// Redesign 2.0 — il quinto spazio: Social come tab, non come stanza nascosta nel profilo.
///
/// Dentro ci stanno solo dati veri: il feed delle liste pubbliche (già esistente, prima
/// annidato dentro Liste) e la ricerca utenti (prima raggiungibile solo dal profilo). Un feed
/// di attività degli amici non ha ancora una sorgente server: quando esisterà, la sua casa è
/// questa schermata — non si mostra un placeholder finto nel frattempo.
struct SocialView: View {
    @State private var showUserSearch = false
    /// Redesign 2.0: l'header globale è persistente su ogni tab (prototipo).
    @EnvironmentObject var appState: AppState
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var showSearch = false
    @State private var showProfile = false

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

            // Il feed delle liste pubbliche: ricerca, Esplora/Seguite, follow ottimistico.
            // È lo stesso componente che viveva nel tab Liste — Liste ora è solo l'archivio
            // personale, e ciò che è pubblico e sociale abita qui.
            PublicListsView()
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
    }
}
