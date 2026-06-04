import SwiftUI

struct SeasonDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: SeasonDetailViewModel
    @StateObject private var episodeSeenManager = EpisodeSeenManager.shared
    @StateObject private var listManager = ListManager.shared

    let showId: Int
    let showName: String
    let showBackdropPath: String?
    let showPosterPath: String?
    let tvShow: TVShow?
    let cast: [Cast]
    let director: Crew?

    @State private var showSavePanel = false
    @State private var selectedActor: Cast?

    init(showId: Int, seasonNumber: Int, showName: String, showBackdropPath: String?, showPosterPath: String? = nil, tvShow: TVShow? = nil, cast: [Cast] = [], director: Crew? = nil) {
        _viewModel = StateObject(wrappedValue: SeasonDetailViewModel(showId: showId, seasonNumber: seasonNumber))
        self.showId = showId
        self.showName = showName
        self.showBackdropPath = showBackdropPath
        self.showPosterPath = showPosterPath
        self.tvShow = tvShow
        self.cast = cast
        self.director = director
    }

    private var heroURL: URL? {
        if let path = viewModel.season?.posterPath {
            return URL(string: "https://image.tmdb.org/t/p/w780\(path)")
        }
        if let path = showBackdropPath {
            return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
        }
        return nil
    }

    private var seasonNumber: Int {
        viewModel.season?.seasonNumber ?? 0
    }

    private var isInWatchlist: Bool {
        listManager.isInList(listId: listManager.watchlist.id, mediaId: showId, mediaType: .tv)
    }

    private var isSeasonSeen: Bool {
        guard let episodes = viewModel.season?.episodes else { return false }
        return episodeSeenManager.isSeasonFullySeen(showId: showId, seasonNumber: seasonNumber, episodes: episodes)
    }

    private func showMovie() -> Movie {
        Movie(
            id: showId,
            title: showName,
            overview: "",
            posterPath: showPosterPath,
            backdropPath: showBackdropPath,
            releaseDate: nil,
            voteAverage: 0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()

            if viewModel.isLoading && viewModel.season == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error, viewModel.season == nil {
                errorView(error)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            SeasonDetailHeaderView(
                                heroURL: heroURL,
                                seasonName: viewModel.season.map { "\(showName) – \($0.name)" } ?? showName,
                                onDismiss: { dismiss() }
                            )

                            VStack(spacing: 24) {
                                if let season = viewModel.season {
                                    seasonInfoSection(season: season)
                                    seasonActionsSection(season: season)
                                    episodesSection(episodes: season.episodes)
                                    seasonDetailsInfoSection(season: season)
                                }
                            }
                            .padding(.horizontal, DetailLayout.seasonContentHorizontalInset)
                            .padding(.bottom, 40)
                        }
                        .frame(width: geometry.size.width)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .swipeBackGesture { dismiss() }
        .task { await viewModel.loadSeasonDetails() }
        .sheet(isPresented: $showSavePanel) {
            SaveToListPanel(movie: showMovie(), mediaType: .tv)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.theme.background)
        }
        .navigationDestination(item: $selectedActor) { actor in
            ActorDetailView(
                actorId: actor.id,
                initialName: actor.name,
                initialProfileURL: actor.profileURL,
                previousTitle: showName
            )
        }
    }

    // MARK: - Sections

    private func seasonInfoSection(season: SeasonDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Text("\(season.episodeCount) episodes")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)

                if let year = season.year {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 3))
                        .foregroundColor(Color.white.opacity(0.4))
                        .padding(.horizontal, 6)
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 10)

                HStack(spacing: 4) {
                    Text("\(Int(season.voteAverage * 10))%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(showName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(season.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
            }

            if !season.overview.isEmpty {
                Text(season.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func seasonDetailsInfoSection(season: SeasonDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("movieDetail.information".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)

                VStack(alignment: .leading, spacing: 12) {
                    if Int(season.voteAverage * 10) > 0 {
                        InfoRow(title: "movieDetail.rating".localized, value: "\(Int(season.voteAverage * 10))%")
                    }

                    if let genres = tvShow?.genres, !genres.isEmpty {
                        InfoRow(title: "movieDetail.genres".localized, value: genres.map { $0.name }.joined(separator: ", "))
                    }

                    if let runtime = tvShow?.formattedEpisodeRuntime {
                        InfoRow(title: "movieDetail.runtime".localized, value: runtime)
                    }

                    if let countries = tvShow?.productionCountries, !countries.isEmpty {
                        InfoRow(title: "movieDetail.country".localized, value: countries.first?.name ?? "")
                    }

                    if let director = director {
                        InfoRow(title: "movieDetail.director".localized, value: director.name)
                    }
                }
            }
            .padding(.horizontal, 20)

            if !cast.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("movieDetail.cast".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cast) { actor in
                                CastMemberCard(actor: actor) {
                                    selectedActor = actor
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    private func seasonActionsSection(season: SeasonDetail) -> some View {
        HStack(spacing: 12) {
            ActionButton(
                icon: "bookmark.fill",
                title: "movieDetail.save".localized,
                isActive: isInWatchlist
            ) {
                showSavePanel = true
            }

            ActionButton(
                icon: "checkmark.circle.fill",
                title: "S\(season.seasonNumber) \("tvDetail.seasonSeenShort".localized)",
                isActive: isSeasonSeen
            ) {
                withAnimation {
                    toggleSeasonSeen(episodes: season.episodes, seasonNumber: season.seasonNumber)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func episodesSection(episodes: [Episode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodes")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                ForEach(episodes) { episode in
                    EpisodeRow(
                        episode: episode,
                        isSeen: episodeSeenManager.isEpisodeSeen(
                            showId: showId,
                            seasonNumber: episode.seasonNumber,
                            episodeNumber: episode.episodeNumber
                        ),
                        onToggleSeen: {
                            episodeSeenManager.toggleEpisode(
                                showId: showId,
                                seasonNumber: episode.seasonNumber,
                                episodeNumber: episode.episodeNumber,
                                allEpisodesInSeason: episodes
                            )
                        }
                    )
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleSeasonSeen(episodes: [Episode], seasonNumber: Int) {
        if episodeSeenManager.isSeasonFullySeen(showId: showId, seasonNumber: seasonNumber, episodes: episodes) {
            episodeSeenManager.unmarkSeasonSeen(showId: showId, seasonNumber: seasonNumber, episodes: episodes)
        } else {
            episodeSeenManager.markSeasonSeen(showId: showId, seasonNumber: seasonNumber, episodes: episodes)
        }
    }

    // MARK: - Error

    private func errorView(_ error: AppError) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(error.errorDescription ?? "Oops!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Button {
                Task { await viewModel.loadSeasonDetails() }
            } label: {
                Text("common.tryAgain".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(Color.orange)
                    .cornerRadius(25)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

struct SeasonDetailHeaderView: View {
    let heroURL: URL?
    let seasonName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            CachedAsyncImage(url: heroURL)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.clear, Color.theme.background.opacity(0.8), Color.theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }

                Spacer()

                Text(seasonName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 64)
            .padding(.top, 30)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: Episode
    let isSeen: Bool
    let onToggleSeen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncImage(url: episode.stillURL, maxPixelSize: 600)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(Color.theme.cardBackground.clipShape(RoundedRectangle(cornerRadius: 8)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("S\(episode.seasonNumber)E\(episode.episodeNumber) - \(episode.name)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let date = episode.airDateFormatted {
                            Text(date)
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                        }

                        if let runtime = episode.formattedRuntime {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                            Text(runtime)
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }

                    if episode.voteAverage > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.theme.accentOrange)
                            Text(String(format: "%.1f", episode.voteAverage))
                                .font(.system(size: 12))
                                .foregroundColor(.theme.accentOrange)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(action: onToggleSeen) {
                    ZStack {
                        Circle()
                            .fill(isSeen ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: isSeen ? "checkmark.circle.fill" : "checkmark")
                            .font(.system(size: isSeen ? 20 : 16, weight: .semibold))
                            .foregroundColor(isSeen ? .green : .theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if !episode.overview.isEmpty {
                Text(episode.overview)
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(3)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
