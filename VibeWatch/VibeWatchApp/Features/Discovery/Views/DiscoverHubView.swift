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
            DiscoverModeSwitcher(mode: $mode)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                // Lo switcher galleggia sul nero dei clip, non su theme.background: il feed
                // video è l'unica superficie dell'app volutamente a nero pieno.
                .background(Color.black)

            ClipsView()
        }
        .background(Color.black.ignoresSafeArea())
    }
}
