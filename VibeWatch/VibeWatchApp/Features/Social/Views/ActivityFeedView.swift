import SwiftUI
import UIKit

/// Il feed attività di uno scope (chi seguo / community): pull-to-refresh, paginazione a
/// sentinella e i tre stati onesti di PublicListsView — spinner solo al primo carico, errore
/// col retry, vuoto con la sua voce. Nessuno stato finto: se non ci sono card, si dice.
struct ActivityFeedView: View {
    @StateObject private var viewModel: ActivityFeedViewModel

    /// La CTA del vuoto "Following": trova gente da seguire.
    @State private var showUserSearch = false
    /// Il profilo dell'autore si presenta come sheet, stessa porta di MainTabView (§9.4):
    /// NavigationStack proprio + chiusura esplicita, perché lo swipe non si vede.
    @State private var profileTarget: FeedProfileTarget?
    /// Il dettaglio del titolo naviga nello stack esistente, come le righe di ListsView.
    @State private var detailTarget: FeedDetailTarget?
    @State private var shareTarget: FeedShareTarget?

    init(scope: ActivityFeedScope) {
        _viewModel = StateObject(wrappedValue: ActivityFeedViewModel(scope: scope))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                errorState(error)
            } else if viewModel.items.isEmpty {
                emptyState
            } else {
                feed
            }
        }
        .task {
            if viewModel.items.isEmpty { await viewModel.reload() }
        }
        .sheet(isPresented: $showUserSearch) {
            UserSearchView()
        }
        .sheet(item: $profileTarget) { target in
            NavigationStack {
                PublicProfileView(username: target.username)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { profileTarget = nil } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .accessibilityLabel(Text("common.close".localized))
                        }
                    }
            }
        }
        .sheet(item: $shareTarget) { target in
            ShareCardSheet(content: target.content, link: target.link, onClose: { shareTarget = nil })
        }
        .navigationDestination(item: $detailTarget) { target in
            if target.mediaType == "movie" {
                MovieDetailView(movieId: target.tmdbId)
            } else {
                TVShowDetailView(tvShowId: target.tmdbId)
            }
        }
    }

    // MARK: - Feed

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // enumerated per sapere DOVE siamo: la strip "Popolari" della community
                // si infila dopo le prime tre card, non in coda.
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    ActivityCardView(
                        item: item,
                        isOwnCard: viewModel.isOwnCard(item),
                        onOpenProfile: { username in profileTarget = FeedProfileTarget(username: username) },
                        onOpenDetail: { openDetail(for: item) },
                        onShare: { share(item) },
                        onToggleLike: { Task { await viewModel.toggleLike(for: item) } },
                        onCommentCountChanged: { count in viewModel.setCommentCount(count, for: item.id) },
                        onReportReview: { reportReview(item) },
                        onHide: { Task { await viewModel.hide(item) } }
                    )
                    .task { await viewModel.loadMoreIfNeeded(current: item) }

                    if viewModel.scope == .community && index == 2 {
                        popularSection
                    }
                }

                if viewModel.isLoading && !viewModel.items.isEmpty {
                    ProgressView().padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .refreshable { await viewModel.reload() }
    }

    private func openDetail(for item: ActivityItem) {
        guard let tmdbId = item.tmdbId, let mediaType = item.mediaType else { return }
        detailTarget = FeedDetailTarget(mediaType: mediaType, tmdbId: tmdbId)
    }

    /// Segnala la review della card (conferma già raccolta dal dialog della card). La RPC è
    /// idempotente sul server: se fallisce si dice e basta — ripremerla non duplica niente.
    private func reportReview(_ item: ActivityItem) {
        guard let reviewId = item.reviewId else { return }
        Task {
            do {
                try await ActivityInteractionService.shared.report(
                    type: .review, contentId: reviewId)
                ToastCenter.shared.show(success: "social.report.done".localized)
            } catch {
                ToastCenter.shared.show(error: "social.report.failed".localized)
            }
        }
    }

    /// Costruisce il modello della share card e apre il foglio. Il poster si scarica prima
    /// (le card condivisibili sono valori puri, si rasterizzano al primo frame): se manca,
    /// il placeholder della card tiene comunque in piedi l'immagine.
    private func share(_ item: ActivityItem) {
        Task {
            let poster = await ShareCardRenderer.posterImage(path: item.posterPath)
            let title = item.title ?? "social.card.unknownTitle".localized
            // Lo username arriva dal server insieme alla card, quindi l'indirizzo è costruibile
            // senza una seconda lettura. Manca solo su un profilo senza username: firma sì,
            // link no — mai un indirizzo che non risponde.
            let identity = item.username.map(ShareCardIdentity.Identity.other(username:))

            let content: ShareCardContent
            switch item.activityType {
            case .showCompleted:
                content = .showCompleted(.init(
                    title: title,
                    episodesWatched: item.episodeCount ?? 0,
                    totalHours: nil,
                    username: identity?.handle ?? "",
                    profileLink: identity?.drawnLink,
                    poster: poster))
            default:
                content = .ratedTitle(.init(
                    title: title,
                    rating: item.rating ?? 0,
                    review: item.reviewContent,
                    username: identity?.handle ?? "",
                    profileLink: identity?.drawnLink,
                    poster: poster))
            }
            shareTarget = FeedShareTarget(content: content, link: identity?.profileURL)
        }
    }

    // MARK: - Popolari questa settimana (community)

    /// Costruita SOLO dai dati della pagina (min. 2 ricorrenze): quando nessun titolo
    /// qualifica, la sezione non esiste — mai una strip riempita per far scena.
    @ViewBuilder
    private var popularSection: some View {
        let popular = viewModel.popularThisWeek
        if !popular.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("social.feed.popular.title".localized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(popular) { entry in
                            Button {
                                detailTarget = FeedDetailTarget(mediaType: entry.mediaType, tmdbId: entry.tmdbId)
                            } label: {
                                popularPoster(entry)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func popularPoster(_ entry: PopularFeedTitle) -> some View {
        if let path = entry.posterPath,
           let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
            CachedAsyncImage(url: url, maxPixelSize: 400) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
            }
            .frame(width: 90, height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Stati vuoti / errore

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.scope == .following ? "person.2" : "globe")
                .font(.system(size: 56))
                .foregroundColor(.theme.textSecondary)

            if viewModel.scope == .following {
                Text("social.feed.empty.following.title".localized)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)

                Text("social.feed.empty.following.message".localized)
                    .font(.system(size: 15))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button { showUserSearch = true } label: {
                    Text("social.feed.empty.following.cta".localized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.theme.accentOrange)
                        .clipShape(Capsule())
                }
                .padding(.top, 4)
            } else {
                // La community vuota è un momento, non un fallimento: copy più leggero.
                Text("social.feed.empty.community".localized)
                    .font(.system(size: 15))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 56))
                .foregroundColor(.theme.textSecondary)

            Text("social.feed.error".localized)
                .font(.system(size: 15))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task { await viewModel.reload() }
            } label: {
                Text("common.retry".localized)
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
}

// MARK: - Target di presentazione

/// Wrapper Identifiable per gli sheet/navigazione item-based: una String da sola non basta.
private struct FeedProfileTarget: Identifiable {
    let username: String
    var id: String { username }
}

private struct FeedDetailTarget: Identifiable, Hashable {
    let mediaType: String
    let tmdbId: Int
    var id: String { "\(mediaType)-\(tmdbId)" }
}

private struct FeedShareTarget: Identifiable {
    let id = UUID()
    let content: ShareCardContent
    /// L'indirizzo del profilo che accompagna la card nella share sheet.
    let link: URL?
}

// MARK: - Preview

#Preview("Feed following") {
    NavigationStack {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            ActivityFeedView(scope: .following)
        }
    }
}
