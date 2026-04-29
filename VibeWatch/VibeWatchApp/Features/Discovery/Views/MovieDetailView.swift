import SwiftUI
import YouTubeiOSPlayerHelper
import UIKit

struct MovieDetailView: View {
    @Environment(\.mediaRepository) private var mediaRepository
    private let movieId: Int

    init(movieId: Int) {
        self.movieId = movieId
    }

    var body: some View {
        MovieDetailContentView(movieId: movieId, mediaRepository: mediaRepository)
    }
}

private struct MovieDetailContentView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.listRepository) private var listRepository
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var viewModel: MovieDetailViewModel
    @State private var lists: [MediaList] = []
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var showSavePanel = false
    @State private var showAuthGate = false
    @State private var showSearch = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    @State private var showReportBug = false
    @State private var selectedActor: Cast?
    @State private var filmographySelection: FilmographySelection?
    @State private var showWhyForMeSheet = false
    @State private var showAIPaywall = false
    
    init(movieId: Int, mediaRepository: any MediaRepository) {
        _viewModel = State(initialValue: MovieDetailViewModel(movieId: movieId, mediaRepository: mediaRepository))
    }
    
    private var shouldShowAd: Bool {
        !quotaManager.isProUser
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 100)
                    } else if let error = viewModel.error {
                        errorView(error)
                    } else if let movie = viewModel.movie {
                        MovieDetailHeaderView(
                            movie: movie,
                            onDismiss: { dismiss() },
                            onSearch: { showSearch = true },
                            onShare: {
                                Task {
                                    await handleShare(movie: movie)
                                }
                            }
                        )

                        VStack(spacing: 24) {
                            MovieInfoSection(movie: movie)

                            ActionButtonsSection(
                                isInAnyList: isInAnyList(mediaId: movie.id, mediaType: .movie),
                                isInSeen: isInDefaultList(.seen, mediaId: movie.id, mediaType: .movie),
                                isInLiked: isInDefaultList(.liked, mediaId: movie.id, mediaType: .movie),
                                isInDisliked: isInDefaultList(.disliked, mediaId: movie.id, mediaType: .movie),
                                onSaveTap: {
                                    showSavePanel = true
                                },
                                onSeenTap: {
                                    Task {
                                        await handleSeenTap(movie: movie)
                                    }
                                },
                                onLikedTap: {
                                    Task {
                                        await handleLikedTap(movie: movie)
                                    }
                                },
                                onDislikedTap: {
                                    Task {
                                        await handleDislikedTap(movie: movie)
                                    }
                                }
                            )

                            GoodFitSection(
                                title: String(format: "movieDetail.goodFitTitle".localized, movie.title),
                                subtitle: "movieDetail.goodFitSubtitle".localized,
                                onWhyTap: { handleWhyForMeTap() }
                            )

                            WatchNowSection(
                                providers: viewModel.watchProviders,
                                mediaType: .movie,
                                title: movie.title,
                                year: movie.year,
                                imdbId: viewModel.imdbId,
                                movie: movie,
                                onReportIssue: { showReportBug = true },
                                onNotifyMe: {
                                    Task { await handleAddToWatchlist(movie: movie, mediaType: .movie) }
                                }
                            )

                            if let trailer = viewModel.trailer {
                                TrailerSection(trailer: trailer)
                            }

                            if !viewModel.mainCast.isEmpty || viewModel.director != nil {
                                MovieCreditsSection(
                                    director: viewModel.director,
                                    cast: viewModel.mainCast,
                                    movie: movie,
                                    onActorTap: { actor in
                                        selectedActor = actor
                                    }
                                )
                            }

                            if !viewModel.similarMovies.isEmpty {
                                SimilarMoviesSection(movies: viewModel.similarMovies)
                            }
                        }
                        .padding(.horizontal, 50)
                        .padding(.bottom, shouldShowAd ? 90 : 40)
                    }
                }
            }

            if shouldShowAd {
                BannerAdView(adUnitID: AppConstants.AdMob.bannerAdUnitID)
                    .frame(height: 50)
            }
        }
        .background(Color.theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .swipeBackGesture {
            dismiss()
        }
        .sheet(isPresented: $showSavePanel) {
            if let movie = viewModel.movie {
                SaveToListPanel(movie: movie, mediaType: .movie)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.theme.background)
            }
        }
        .task {
            async let details: () = viewModel.loadMovieDetails()
            async let listLoad: () = loadLists()
            _ = await (details, listLoad)
        }
        .sheet(isPresented: $showSearch) {
            SearchView(viewModel: searchViewModel)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
                .onDisappear {
                    shareItems = []
                }
        }
        .sheet(item: $selectedActor) { actor in
            ActorDetailView(
                actorId: actor.id,
                initialName: actor.name,
                initialProfileURL: actor.profileURL
            ) { credit in
                handleFilmographySelection(credit)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.theme.background)
        }
        .fullScreenCover(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showReportBug) {
            FeedbackDetailSheet(type: .bug)
        }
        .sheet(isPresented: $showWhyForMeSheet) {
            WhyForMeSheetView(
                title: "movieDetail.whyForMe".localized,
                message: viewModel.whyForMeMessage,
                isLoading: viewModel.isWhyForMeLoading,
                error: viewModel.whyForMeError
            ) {
                Task { await viewModel.generateWhyForMe() }
            }
        }
        .fullScreenCover(isPresented: $showAIPaywall) {
            DailyLimitPaywallView(
                isPresented: $showAIPaywall,
                paywallType: .aiQuota,
                source: "why_for_me_quota"
            )
        }
        .fullScreenCover(item: $filmographySelection) { selection in
            switch selection.mediaType {
            case .movie:
                MovieDetailView(movieId: selection.mediaId)
            case .tv:
                TVShowDetailView(tvShowId: selection.mediaId)
            }
        }
        .overlay {
            if isPreparingShare {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
            }
        }
    }
    
    private func errorView(_ error: AppError) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(error.errorDescription ?? "Oops!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            if let recoverySuggestion = error.recoverySuggestion {
                Text(recoverySuggestion)
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                Task {
                    await viewModel.loadMovieDetails()
                }
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
    
    // MARK: - List Helpers

    private var userId: String { appState.currentUser?.id ?? "anonymous" }

    private func defaultList(_ type: ListType) -> MediaList {
        lists.first { $0.type == type } ?? MediaList(name: type.displayName, type: type)
    }

    private func isInDefaultList(_ type: ListType, mediaId: Int, mediaType: MediaType) -> Bool {
        defaultList(type).items.contains { $0.mediaId == mediaId && $0.mediaType == mediaType }
    }

    private func isInAnyList(mediaId: Int, mediaType: MediaType) -> Bool {
        lists.contains { $0.items.contains { $0.mediaId == mediaId && $0.mediaType == mediaType } }
    }

    private func loadLists() async {
        for await snapshot in listRepository.lists(for: userId) {
            lists = snapshot
        }
    }

    private func mediaListItem(from movie: Movie, mediaType: MediaType) -> MediaListItem {
        MediaListItem(
            mediaId: movie.id,
            mediaType: mediaType,
            title: movie.title,
            posterPath: movie.posterPath,
            runtime: movie.runtime,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            releaseDate: movie.releaseDate,
            overview: movie.overview
        )
    }

    private func optimisticAdd(_ item: MediaListItem, to type: ListType) {
        let list = defaultList(type)
        guard !list.items.contains(where: { $0.mediaId == item.mediaId && $0.mediaType == item.mediaType }) else { return }
        var items = list.items
        items.append(item)
        replaceList(MediaList(id: list.id, name: list.name, description: list.description, type: list.type, createdAt: list.createdAt, items: items))
    }

    private func optimisticRemove(_ identifier: MediaIdentifier, from type: ListType) {
        let list = defaultList(type)
        var items = list.items
        items.removeAll { $0.mediaId == identifier.id && $0.mediaType == identifier.mediaType }
        replaceList(MediaList(id: list.id, name: list.name, description: list.description, type: list.type, createdAt: list.createdAt, items: items))
    }

    private func replaceList(_ list: MediaList) {
        if let index = lists.firstIndex(where: { $0.type == list.type }) {
            lists[index] = list
        } else {
            lists.append(list)
        }
    }

    // MARK: - Action Handlers

    private func handleSeenTap(movie: Movie) async {
        let identifier = MediaIdentifier(id: movie.id, mediaType: .movie)
        do {
            if isInDefaultList(.seen, mediaId: movie.id, mediaType: .movie) {
                optimisticRemove(identifier, from: .seen)
                try await listRepository.removeFromDefaultList(type: .seen, identifier: identifier, userId: userId)
            } else {
                let item = mediaListItem(from: movie, mediaType: .movie)
                optimisticAdd(item, to: .seen)
                try await listRepository.addToDefaultList(type: .seen, item: item, userId: userId)
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Seen")
        }
    }

    private func handleWhyForMeTap() {
        guard appState.isAuthenticated else {
            showAuthGate = true
            return
        }

        showWhyForMeSheet = true
        if viewModel.whyForMeMessage?.isEmpty != false {
            Task { await viewModel.generateWhyForMe() }
        }
    }

    private func handleLikedTap(movie: Movie) async {
        let identifier = MediaIdentifier(id: movie.id, mediaType: .movie)
        let wasLiked = isInDefaultList(.liked, mediaId: movie.id, mediaType: .movie)
        let wasDisliked = isInDefaultList(.disliked, mediaId: movie.id, mediaType: .movie)
        do {
            if wasLiked {
                optimisticRemove(identifier, from: .liked)
                try await listRepository.removeFromDefaultList(type: .liked, identifier: identifier, userId: userId)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: movie.id, mediaType: .movie, oldReaction: .like, newReaction: nil
                )
            } else {
                if wasDisliked {
                    optimisticRemove(identifier, from: .disliked)
                    try await listRepository.removeFromDefaultList(type: .disliked, identifier: identifier, userId: userId)
                }
                let item = mediaListItem(from: movie, mediaType: .movie)
                optimisticAdd(item, to: .liked)
                try await listRepository.addToDefaultList(type: .liked, item: item, userId: userId)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: movie.id, mediaType: .movie,
                    oldReaction: wasDisliked ? .dislike : nil, newReaction: .like
                )
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Liked")
        }
    }

    private func handleDislikedTap(movie: Movie) async {
        let identifier = MediaIdentifier(id: movie.id, mediaType: .movie)
        let wasLiked = isInDefaultList(.liked, mediaId: movie.id, mediaType: .movie)
        let wasDisliked = isInDefaultList(.disliked, mediaId: movie.id, mediaType: .movie)
        do {
            if wasDisliked {
                optimisticRemove(identifier, from: .disliked)
                try await listRepository.removeFromDefaultList(type: .disliked, identifier: identifier, userId: userId)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: movie.id, mediaType: .movie, oldReaction: .dislike, newReaction: nil
                )
            } else {
                if wasLiked {
                    optimisticRemove(identifier, from: .liked)
                    try await listRepository.removeFromDefaultList(type: .liked, identifier: identifier, userId: userId)
                }
                let item = mediaListItem(from: movie, mediaType: .movie)
                optimisticAdd(item, to: .disliked)
                try await listRepository.addToDefaultList(type: .disliked, item: item, userId: userId)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: movie.id, mediaType: .movie,
                    oldReaction: wasLiked ? .like : nil, newReaction: .dislike
                )
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Disliked")
        }
    }

    private func handleAddToWatchlist(movie: Movie, mediaType: MediaType) async {
        guard !isInDefaultList(.watchlist, mediaId: movie.id, mediaType: mediaType) else { return }
        let item = mediaListItem(from: movie, mediaType: mediaType)
        optimisticAdd(item, to: .watchlist)
        try? await listRepository.addToDefaultList(type: .watchlist, item: item, userId: userId)
    }
    
    private func handleShare(movie: Movie) async {
        isPreparingShare = true
        await prepareShareItems(movie: movie)
        if !shareItems.isEmpty {
            await MainActor.run {
                isPreparingShare = false
                showShareSheet = true
            }
        } else {
            await MainActor.run {
                isPreparingShare = false
            }
        }
    }
    
    private func prepareShareItems(movie: Movie) async {
        var items: [Any] = []
        if let posterPath = movie.posterPath,
           let url = URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let image = UIImage(data: data) {
            items.append(image)
        }
        var text = "Check out \(movie.title)"
        if let year = movie.year { text += " (\(year))" }
        if !movie.overview.isEmpty { text += "\n\n\(movie.overview)" }
        items.append(text)
        await MainActor.run { shareItems = items }
    }
    
    private func handleFilmographySelection(_ credit: PersonCredit) {
        selectedActor = nil
        filmographySelection = FilmographySelection(mediaType: credit.mediaType, mediaId: credit.id)
    }
}

struct MovieDetailHeaderView: View {
    let movie: Movie
    let onDismiss: () -> Void
    let onSearch: () -> Void
    let onShare: () -> Void
    
    var body: some View {
        ZStack(alignment: .top) {
            CachedAsyncImage(url: movie.backdropURL)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.theme.background.opacity(0.8),
                            Color.theme.background
                        ],
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
                
                Text(movie.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: onSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    
                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 64)
            .padding(.top, 30)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
    }
}

// ... (Other structs remain mostly unchanged, just extracted out logic)

struct MovieInfoSection: View {
    let movie: Movie
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let year = movie.year {
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                
                HStack(spacing: 4) {
                    Text("\(movie.ratingPercentage)%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                    Text("(\(movie.voteCount) \("movieDetail.ratings".localized))")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            
            Text(movie.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if !movie.overview.isEmpty {
                Text(movie.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

struct ActionButtonsSection: View {
    let isInAnyList: Bool
    let isInSeen: Bool
    let isInLiked: Bool
    let isInDisliked: Bool
    var likesCount: Int = 0
    var dislikesCount: Int = 0
    let onSaveTap: () -> Void
    let onSeenTap: () -> Void
    let onLikedTap: () -> Void
    let onDislikedTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(
                icon: "bookmark.fill",
                title: "movieDetail.save".localized,
                isActive: isInAnyList
            ) {
                onSaveTap()
            }

            ActionButton(
                icon: "eye.fill",
                title: "movieDetail.seen".localized,
                isActive: isInSeen
            ) {
                withAnimation {
                    onSeenTap()
                }
            }

            ActionButton(
                icon: "hand.thumbsup.fill",
                title: "",
                isActive: isInLiked,
                count: likesCount
            ) {
                withAnimation {
                    onLikedTap()
                }
            }

            ActionButton(
                icon: "hand.thumbsdown.fill",
                title: "",
                isActive: isInDisliked,
                count: dislikesCount
            ) {
                withAnimation {
                    onDislikedTap()
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

struct ActionButton: View {
    let icon: String
    let title: String?
    let isActive: Bool
    var count: Int? = nil
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                if let title = title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
                if let count = count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isActive ? .theme.accentOrange : .theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .foregroundColor(isActive ? .theme.accentOrange : .theme.textPrimary)
            .background(isActive ? Color.theme.accentOrange.opacity(0.2) : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct TrailerSection: View {
    let trailer: Video
    @State private var isPlaying = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("movieDetail.trailer".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            ZStack {
                if !isPlaying {
                    Button {
                        isPlaying = true
                    } label: {
                        CachedAsyncImage(url: trailer.thumbnailURL)
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white)
                                    .shadow(radius: 10)
                            }
                    }
                } else {
                    YouTubePlayerView(videoId: trailer.key)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(height: 200)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

struct WatchNowSection: View {
    let providers: CountryProviders?
    let mediaType: MediaType
    let title: String
    let year: String?
    let imdbId: String?
    let movie: Movie?
    var onReportIssue: () -> Void = {}
    var onNotifyMe: () -> Void = {}

    @State private var showNotifyMeAlert = false

    private var hasAnyProvider: Bool {
        guard let p = providers else { return false }
        return (p.flatrate?.isEmpty == false) || (p.rent?.isEmpty == false) || (p.buy?.isEmpty == false)
    }

    private var justWatchURL: URL? {
        if let linkString = providers?.link, let url = URL(string: linkString) {
            return url
        }

        let country = LocalizationManager.shared.currentCountry.id.lowercased()
        let encodedQuery = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        return URL(string: "https://www.justwatch.com/\(country)/search?q=\(encodedQuery)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("movieDetail.watchNow".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if hasAnyProvider {
                if let flatrate = providers?.flatrate, !flatrate.isEmpty {
                    ProviderGroup(title: "platforms.streaming".localized, providers: flatrate, justWatchLink: providers?.link, mediaTitle: title)
                }
                
                if let rent = providers?.rent, !rent.isEmpty {
                    ProviderGroup(title: "platforms.rent".localized, providers: rent, justWatchLink: providers?.link, mediaTitle: title)
                }
                
                if let buy = providers?.buy, !buy.isEmpty {
                    ProviderGroup(title: "platforms.buy".localized, providers: buy, justWatchLink: providers?.link, mediaTitle: title)
                }

                if let url = justWatchURL {
                    CinemaJustWatchGroup(title: "platforms.cinema".localized, url: url)
                }
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.theme.accentOrange.opacity(0.15))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.theme.accentOrange)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unluckily \(title) isn't currently available.")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                        
                        Text("Would you like to be notified?")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Button {
                        handleNotifyMe()
                    } label: {
                        Text("Notify Me")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.theme.accentOrange)
                            .clipShape(Capsule())
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            
            Button {
                onReportIssue()
            } label: {
                HStack(spacing: 8) {
                    Text("misc.somethingWrong".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                    Text("misc.letUsKnow".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.theme.accentOrange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .alert("Notify Me", isPresented: $showNotifyMeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("We'll send you a notification as soon as '\(title)' is available for streaming, rent, or buy.")
        }
    }
    
    private func handleNotifyMe() {
        showNotifyMeAlert = true
        onNotifyMe()
    }
}

struct CinemaJustWatchGroup: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            Button {
                UIApplication.shared.open(url, options: [:])
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                        Image(systemName: "ticket.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.black)
                    }
                    .frame(width: 60, height: 60)

                    Text("platforms.justwatch".localized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 80)
                }
                .frame(width: 80)
            }
        }
    }
}

struct ProviderGroup: View {
    let title: String
    let providers: [Provider]
    let justWatchLink: String?
    let mediaTitle: String

    private var visibleProviders: [Provider] {
        providers.filter { provider in
            guard !provider.logoPath.isEmpty else { return false }
            let lowerLogo = provider.logoPath.lowercased()
            if lowerLogo.contains(".svg") { return false }
            if lowerLogo.contains("logo-white") { return false }
            let hasLink = provider.externalLink != nil || justWatchLink != nil
            if hasLink { return true }
            return PlatformDeepLinkHelper.hasPlatformHomepage(for: provider)
        }
    }
    
    var body: some View {
        Group {
            if !visibleProviders.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                    
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 80), spacing: 16)
                    ], spacing: 16) {
                        ForEach(visibleProviders) { (provider: Provider) in
                            Button {
                                PlatformDeepLinkHelper.openPlatform(provider: provider, justWatchLink: justWatchLink, title: mediaTitle)
                            } label: {
                                VStack(spacing: 6) {
                                    CachedAsyncImage(url: provider.logoURL)
                                        .frame(width: 60, height: 60)
                                        .aspectRatio(contentMode: .fit)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    
                                    VStack(spacing: 2) {
                                        if let price = provider.price?.displayPrice {
                                            HStack(spacing: 4) {
                                                Text(price)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(.theme.accentOrange)
                                                
                                                if let quality = provider.formattedQuality {
                                                    Text("•")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.theme.textSecondary)
                                                    
                                                    Text(quality)
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundColor(.theme.textSecondary)
                                                }
                                            }
                                        } else if let quality = provider.formattedQuality {
                                            Text(quality)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.theme.textSecondary)
                                        } else {
                                            Text(" ")
                                                .font(.system(size: 10))
                                        }
                                    }
                                    .frame(height: 16)
                                }
                                .frame(width: 80)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct GoodFitSection: View {
    let title: String
    let subtitle: String
    let onWhyTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)

            Button(action: onWhyTap) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("movieDetail.whyForMe".localized)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}

struct YouTubePlayerView: UIViewRepresentable {
    let videoId: String
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> YTPlayerView {
        let player = YTPlayerView()
        player.delegate = context.coordinator
        player.backgroundColor = .black
        player.isOpaque = false
        return player
    }
    
    func updateUIView(_ playerView: YTPlayerView, context: Context) {
        if context.coordinator.loadedVideoId != videoId {
            context.coordinator.loadedVideoId = videoId
            let vars: [String: Any] = [
                "playsinline": 1,
                "controls": 1,
                "modestbranding": 1,
                "rel": 0,
                "fs": 1,
                "origin": "https://www.vibewatch.app"
            ]
            playerView.load(withVideoId: videoId, playerVars: vars)
        }
    }
    
    @MainActor
    class Coordinator: NSObject, @MainActor YTPlayerViewDelegate {
        var loadedVideoId: String?
        
        func playerViewDidBecomeReady(_ playerView: YTPlayerView) {
            playerView.playVideo()
        }
    }
}

struct WhyForMeSheetView: View {
    let title: String
    let message: String?
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                }
                if isLoading {
                    contentCard {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("common.loading".localized)
                                .font(.system(size: 14))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }
                } else if let error, !error.isEmpty {
                    contentCard {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: onRetry) {
                        Text("common.tryAgain".localized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.theme.accentOrange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else if let message, !message.isEmpty {
                    contentCard {
                        Text(message)
                            .font(.system(size: 15))
                            .foregroundColor(.theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    contentCard {
                        Text("common.loading".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .presentationDetents([.fraction(0.5)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.theme.background)
    }

    @ViewBuilder
    private func contentCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct MovieCreditsSection: View {
    let director: Crew?
    let cast: [Cast]
    let movie: Movie
    let onActorTap: (Cast) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("movieDetail.information".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                
                VStack(alignment: .leading, spacing: 12) {
                    if movie.ratingPercentage > 0 {
                        InfoRow(title: "movieDetail.rating".localized, value: "\(movie.ratingPercentage)%")
                    }
                    
                    if let genres = movie.genres, !genres.isEmpty {
                        InfoRow(title: "movieDetail.genres".localized, value: genres.map { $0.name }.joined(separator: ", "))
                    }
                    
                    if let runtime = movie.formattedRuntime {
                        InfoRow(title: "movieDetail.runtime".localized, value: runtime)
                    }
                    
                    if let countries = movie.productionCountries, !countries.isEmpty {
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
                                    onActorTap(actor)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14))
                .foregroundColor(.theme.textPrimary)
            
            Spacer()
        }
    }
}

struct CastMemberCard: View {
    let actor: Cast
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(spacing: 8) {
                CachedAsyncImage(url: actor.profileURL)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                
                VStack(spacing: 2) {
                    Text(actor.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)
                    
                    Text(actor.character)
                        .font(.system(size: 10))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 80)
            }
        }
    }
}

struct SimilarMoviesSection: View {
    let movies: [Movie]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("movieDetail.similar".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(movies) { movie in
                        NavigationLink(destination: MovieDetailView(movieId: movie.id)) {
                            MediaCard(movie: movie, description: nil)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
