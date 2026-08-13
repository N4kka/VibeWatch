import SwiftUI

/// SPEC v3 §9.3 — il profilo di un altro utente, versione blocco 8.
///
/// Header con avatar, nome, @username, bio e contatori, più il pulsante segui/seguito. Favorites,
/// stats e diario sono §9.3 pieno e arrivano col blocco 9: la struttura è già una destinazione
/// (`/@{username}` la aggancerà con gli universal links del blocco 10).
struct PublicProfileView: View {
    @StateObject private var viewModel: PublicProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showBlockConfirm = false

    init(username: String) {
        _viewModel = StateObject(wrappedValue: PublicProfileViewModel(username: username))
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("@\(viewModel.username)")
        .navigationBarTitleDisplayMode(.inline)
        // Moderazione M2: il menu "…" con blocca/sblocca. Solo su un profilo carico e altrui —
        // un'azione che il server rifiuterebbe non merita un pulsante (lezione del self-follow).
        .toolbar {
            if viewModel.canModerate {
                ToolbarItem(placement: .navigationBarTrailing) {
                    moderationMenu
                }
            }
        }
        // Il blocco chiede conferma spiegando le conseguenze: è un'azione a tre effetti
        // (visibilità nei due versi + follow rimossi) e nessuno dei tre si vede da qui.
        .confirmationDialog(
            String(format: "social.block.confirmTitle".localized, viewModel.username),
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("social.block.confirm".localized, role: .destructive) {
                Task { await performBlock() }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("social.block.consequences".localized)
        }
        .task { await viewModel.loadProfile() }
    }

    private var moderationMenu: some View {
        Menu {
            if viewModel.isBlocked {
                Button {
                    Task { await performUnblock() }
                } label: {
                    Label(String(format: "social.unblockUser".localized, viewModel.username),
                          systemImage: "hand.raised.slash")
                }
            } else {
                Button(role: .destructive) {
                    showBlockConfirm = true
                } label: {
                    Label(String(format: "social.blockUser".localized, viewModel.username),
                          systemImage: "hand.raised")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(viewModel.isTogglingBlock)
    }

    /// Toast e poi via dalla schermata: dopo il blocco il server nasconde il profilo nei due
    /// versi, e restare su una pagina che al prossimo refresh direbbe "non esiste" è bugiardo.
    private func performBlock() async {
        if await viewModel.blockProfile() {
            ToastCenter.shared.show(success: "social.block.done".localized)
            dismiss()
        } else {
            ToastCenter.shared.show(error: "common.error".localized)
        }
    }

    private func performUnblock() async {
        if await viewModel.unblockProfile() {
            ToastCenter.shared.show(success: "social.unblock.done".localized)
        } else {
            ToastCenter.shared.show(error: "common.error".localized)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
        case .notFound:
            message(icon: "person.slash", textKey: "social.profile.notFound")
        case .failed:
            VStack(spacing: 12) {
                message(icon: "wifi.exclamationmark", textKey: "social.profile.loadFailed")
                Button("common.retry".localized) {
                    Task { await viewModel.loadProfile() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
        case .loaded(let detail):
            ScrollView {
                VStack(spacing: 20) {
                    header(detail)
                    counters(detail)
                    // Sul proprio profilo il pulsante non esiste: un self-follow morirebbe sul
                    // CHECK del server come rifiuto muto, e un pulsante che non fa niente invita
                    // a ripremere (trovato sul dispositivo il 2026-07-31).
                    if viewModel.isOwnProfile {
                        Text("social.profile.you".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                    } else {
                        followButton(detail)
                    }
                    if let bio = detail.profile.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                    }
                    // §9.3: due righe da 4. Una riga vuota non si mostra — un profilo senza
                    // favorites non è un profilo rotto.
                    if !detail.favoriteMovies.isEmpty {
                        favoritesRow(titleKey: "profile.favorites.movies",
                                     slots: detail.favoriteMovies, mediaType: "movie")
                    }
                    if !detail.favoriteShows.isEmpty {
                        favoritesRow(titleKey: "profile.favorites.shows",
                                     slots: detail.favoriteShows, mediaType: "tv")
                    }
                    publicListsSection
                }
                .padding(.vertical, 24)
            }
        }
    }

    /// §9.3, ultimo bullet: le liste pubbliche dell'utente. Tre stati e nessuna finzione:
    /// vuoto = niente sezione (un profilo senza liste non è rotto), errore = riga con
    /// riprova (mai travestito da vuoto), carico = le card del feed, stessa strada
    /// (`PublicListDetailView`), col follow che funziona davvero.
    @ViewBuilder
    private var publicListsSection: some View {
        switch viewModel.listsPhase {
        case .loading:
            EmptyView()
        case .failed:
            VStack(spacing: 6) {
                Text("profile.lists.loadFailed".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
                Button("common.retry".localized) {
                    Task { await viewModel.retryLists() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
            .padding(.horizontal, 24)
        case .loaded(let lists):
            if !lists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("profile.lists.title".localized)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                    ForEach(lists) { list in
                        NavigationLink(destination: PublicListDetailView(list: list)) {
                            PublicListCard(list: list, onToggleFollow: {
                                Task { await viewModel.toggleListFollow(list) }
                            })
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
            }
        }
    }

    private func favoritesRow(titleKey: String, slots: [FavoriteSlot], mediaType: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey.localized)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(slots) { slot in
                    FavoritePosterTile(mediaType: mediaType, tmdbId: slot.tmdbId)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private func header(_ detail: PublicProfileDetail) -> some View {
        VStack(spacing: 10) {
            avatar(detail.profile)
            VStack(spacing: 3) {
                Text(detail.profile.displayName ?? detail.profile.username)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                HStack(spacing: 6) {
                    Text("@\(detail.profile.username)")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                    if detail.followsMe {
                        Text("social.followsYou".localized)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func counters(_ detail: PublicProfileDetail) -> some View {
        HStack(spacing: 32) {
            counter(value: detail.followers, labelKey: "social.profile.followers")
            counter(value: detail.following, labelKey: "social.profile.following")
        }
    }

    private func counter(value: Int, labelKey: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            Text(labelKey.localized)
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
        }
    }

    /// Un'azione per volta e stato in volo visibile: fra il tap e i contatori aggiornati c'è un
    /// giro di rete, e un pulsante muto invita a premere di nuovo (imparato col segno di spunta
    /// del tracking).
    private func followButton(_ detail: PublicProfileDetail) -> some View {
        Button {
            Task { await viewModel.toggleFollow() }
        } label: {
            Group {
                if viewModel.isTogglingFollow {
                    ProgressView().tint(detail.isFollowing ? .white : .black)
                } else {
                    Text((detail.isFollowing ? "social.unfollow" : "social.follow").localized)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 180, height: 40)
            .foregroundColor(detail.isFollowing ? .theme.textPrimary : .black)
            .background(detail.isFollowing ? Color.white.opacity(0.1) : Color.theme.accentOrange)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(detail.isFollowing ? Color.white.opacity(0.2) : .clear, lineWidth: 1)
            )
        }
        .disabled(viewModel.isTogglingFollow)
    }

    private func avatar(_ profile: PublicProfile) -> some View {
        Group {
            if let urlString = profile.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder(profile)
                }
            } else {
                avatarPlaceholder(profile)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func avatarPlaceholder(_ profile: PublicProfile) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Text(String(profile.username.prefix(1)).uppercased())
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
    }

    private func message(icon: String, textKey: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
            Text(textKey.localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}
