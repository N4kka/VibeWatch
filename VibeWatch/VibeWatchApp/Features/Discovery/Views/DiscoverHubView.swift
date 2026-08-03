import SwiftUI

/// Redesign 2.0 — la casa comune di Scopri e Clip.
///
/// I due ex-tab diventano due modalità della stessa area: la barra guadagna lo slot per Social
/// restando a 4 tab. La modalità la possiede `MainTabView` (via binding) perché i deep link e le
/// notifiche di navigazione (`.navigateToClipsTab`) devono poterla impostare da fuori.
struct DiscoverHubView: View {
    @Binding var selectedMovie: Movie?
    @Binding var selectedMediaType: MediaType
    @Binding var mode: DiscoverMode

    /// L'header globale del prototipo è visibile anche in modalità clip: qui servono le sue
    /// azioni (ricerca globale e profilo) perché ClipsView non le possiede — la sua ricerca è
    /// quella dei clip, un'altra cosa.
    @EnvironmentObject var appState: AppState
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var showSearch = false
    @State private var showProfile = false

    var body: some View {
        ZStack {
            // `if` e non `opacity`: ClipsView monta player YouTube veri, e da smontata non deve
            // né suonare né consumare. È lo stesso pattern del vecchio tab.
            if mode == .discover {
                DiscoveryView(
                    selectedMovie: $selectedMovie,
                    selectedMediaType: $selectedMediaType,
                    discoverMode: $mode
                )
                .transition(.opacity)
            } else {
                clipsMode
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private var clipsMode: some View {
        VStack(spacing: 0) {
            // L'header globale resta al suo posto anche sui clip: nel prototipo è fisso su
            // ogni tab e su entrambe le modalità di Scopri. Niente filtri qui: filtrano le
            // raccomandazioni, non il feed video.
            AppHeaderView(
                onSearchTap: { showSearch = true },
                onProfileTap: { showProfile = true },
                avatarURL: appState.currentUser?.avatarURL
            )

            // Niente background opaco incollato alla pill: ora lo switcher È liquid glass
            // (come la bottom bar) e un riempimento nero dietro annullerebbe il materiale.
            // Il nero pieno del feed video lo mette già il background del contenitore.
            DiscoverModeSwitcher(mode: $mode)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)

            ClipsView()
        }
        .background(Color.black.ignoresSafeArea())
        // Sui clip la lente cerca clip: il dock di ricerca dentro il feed non esiste più
        // (redesign 2.0), quindi l'unica porta verso ClipsSearchView è questa.
        .fullScreenCover(isPresented: $showSearch) {
            NavigationStack {
                ClipsSearchView(initialQuery: nil)
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
    }
}
