import SwiftUI
import WebKit

struct TVShowDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @StateObject private var viewModel: TVShowDetailViewModel
    @StateObject private var listManager = ListManager.shared
    @StateObject private var episodeSeenManager = EpisodeSeenManager.shared
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var showSavePanel = false
    @State private var showAuthGate = false
    @State private var showSearch = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    @State private var showReportBug = false
    @State private var selectedActor: Cast?
    @State private var showWhyForMeSheet = false
    @State private var showAIPaywall = false
    @State private var showMarkAllSeenConfirmation = false
    
    init(tvShowId: Int) {
        _viewModel = StateObject(wrappedValue: TVShowDetailViewModel(tvShowId: tvShowId))
    }
    
    private func tvShowToMovie(_ tvShow: TVShow) -> Movie {
        Movie(
            id: tvShow.id,
            title: tvShow.name,
            overview: tvShow.overview,
            posterPath: tvShow.posterPath,
            backdropPath: tvShow.backdropPath,
            releaseDate: tvShow.firstAirDate,
            voteAverage: tvShow.voteAverage,
            voteCount: tvShow.voteCount,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: tvShow.originalLanguage,
            popularity: tvShow.popularity,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: tvShow.imdbId
        )
    }

    private var shouldShowAd: Bool {
        !quotaManager.isProUser
    }

    private var isAllSeasonsSeen: Bool {
        guard let tvShow = viewModel.tvShow, !viewModel.displaySeasons.isEmpty else { return false }
        if episodeSeenManager.seenShowIds.contains(tvShow.id) { return true }
        return viewModel.displaySeasons.allSatisfy { season in
            guard season.episodeCount > 0 else { return true }
            return (1...season.episodeCount).allSatisfy { epNum in
                episodeSeenManager.isEpisodeSeen(
                    showId: tvShow.id,
                    seasonNumber: season.seasonNumber,
                    episodeNumber: epNum
                )
            }
        }
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
                    } else if let tvShow = viewModel.tvShow {
                        let tvShowMovie = tvShowToMovie(tvShow)

                        TVShowDetailHeaderView(
                            tvShow: tvShow,
                            onDismiss: { dismiss() },
                            onSearch: { showSearch = true },
                            onShare: {
                                Task { await handleShare(tvShow: tvShow) }
                            }
                        )

                        VStack(spacing: 24) {
                            infoView(tvShow: tvShow)

                            if !viewModel.displaySeasons.isEmpty {
                                seasonsView(tvShow: tvShow)
                            }

                            actionsView(tvShow: tvShow, movie: tvShowMovie)
                            providersView
                            trailerView
                            creditsView(tvShow: tvShow)
                            similarView
                        }
                        .padding(.horizontal, DetailLayout.contentHorizontalInset)
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
            if let tvShow = viewModel.tvShow {
                SaveToListPanel(movie: tvShowToMovie(tvShow), mediaType: .tv)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.theme.background)
            }
        }
        .sheet(isPresented: $showMarkAllSeenConfirmation) {
            if let tvShow = viewModel.tvShow {
                let movie = tvShowToMovie(tvShow)
                MarkAllSeenConfirmationSheet(
                    onConfirm: {
                        showMarkAllSeenConfirmation = false
                        EpisodeSeenManager.shared.markShowSeen(showId: tvShow.id)
                        Task { await handleSeenTap(tvShow: tvShow, movie: movie) }
                    },
                    onCancel: {
                        showMarkAllSeenConfirmation = false
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.theme.background)
            }
        }
        .task {
            await viewModel.loadTVShowDetails()
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
        .navigationDestination(item: $selectedActor) { actor in
            ActorDetailView(
                actorId: actor.id,
                initialName: actor.name,
                initialProfileURL: actor.profileURL,
                previousTitle: viewModel.tvShow?.name ?? ""
            )
        }
        .fullScreenCover(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
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
        .sheet(isPresented: $showReportBug) {
            FeedbackDetailSheet(type: .bug)
        }
        .onChange(of: isAllSeasonsSeen) { newValue in
            guard newValue else { return }
            Task { await syncShowSeen() }
        }
    }
    
    // MARK: - Error View
    
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
                    await viewModel.loadTVShowDetails()
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
    
    private func infoView(tvShow: TVShow) -> some View {
        TVShowInfoSection(tvShow: tvShow)
    }
    
    private func actionsView(tvShow: TVShow, movie: Movie) -> some View {
                        VStack(spacing: 20) {
                        ActionButtonsSection(
                            movie: movie,
                            mediaType: .tv,
                            onSaveTap: {
                                // Allow anonymous users to open save panel
                                // They can save to watchlist without authentication
                                // Auth gate will show when they try to create custom lists
                                showSavePanel = true
                            },
                            onSeenTap: {
                                if listManager.isInList(listId: listManager.seenList.id, mediaId: tvShow.id, mediaType: .tv) {
                                    Task { await handleSeenTap(tvShow: tvShow, movie: movie) }
                                } else {
                                    showMarkAllSeenConfirmation = true
                                }
                            },
                            onLikedTap: { Task { await handleLikedTap(tvShow: tvShow, movie: movie) } },
                            onDislikedTap: { Task { await handleDislikedTap(tvShow: tvShow, movie: movie) } }
                        )
                        GoodFitSection(
                            title: String(format: "movieDetail.goodFitTitle".localized, tvShow.name),
                            subtitle: "movieDetail.goodFitSubtitle".localized,
                            onWhyTap: { handleWhyForMeTap() }
                        )
                        }
    }
    
    @ViewBuilder
    private var providersView: some View {
        if let tvShow = viewModel.tvShow {
            let tvShowMovie = tvShowToMovie(tvShow)
            WatchNowSection(
                providerState: viewModel.watchProviderState,
                mediaType: .tv,
                title: tvShow.name,
                year: tvShow.year,
                imdbId: viewModel.imdbId,
                movie: tvShowMovie,
                onReportIssue: { showReportBug = true }
            )
        }
    }
    
    @ViewBuilder
    private var trailerView: some View {
        if let trailer = viewModel.trailer {
            TrailerSection(trailer: trailer)
        }
    }
    
    @ViewBuilder
    private func creditsView(tvShow: TVShow) -> some View {
        TVShowCreditsSection(
            director: viewModel.director,
            cast: viewModel.mainCast,
            tvShow: tvShow,
            onActorTap: { actor in
                selectedActor = actor
            }
        )
    }
    
    @ViewBuilder
    private func seasonsView(tvShow: TVShow) -> some View {
        SeasonsCarouselSection(
            seasons: viewModel.displaySeasons,
            showId: tvShow.id,
            showName: tvShow.name,
            showBackdropPath: tvShow.backdropPath,
            showPosterPath: tvShow.posterPath,
            tvShow: tvShow,
            cast: viewModel.mainCast,
            director: viewModel.director
        )
    }

    @ViewBuilder
    private var similarView: some View {
        if !viewModel.similarShows.isEmpty {
            SimilarTVShowsSection(tvShows: viewModel.similarShows)
        }
    }
    
    // MARK: - Actions
    
    private func syncShowSeen() async {
        guard let tvShow = viewModel.tvShow else { return }
        let movie = tvShowToMovie(tvShow)
        do {
            if !listManager.isInList(listId: listManager.seenList.id, mediaId: tvShow.id, mediaType: .tv) {
                try await listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: .tv)
            }
            if let item = listManager.watchlist.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                try await listManager.removeFromList(listId: listManager.watchlist.id, itemId: item.id)
            }
        } catch {
            // Non-critical background sync
        }
    }

    private func handleSeenTap(tvShow: TVShow, movie: Movie) async {
        do {
            if listManager.isInList(listId: listManager.seenList.id, mediaId: tvShow.id, mediaType: .tv) {
                if let item = listManager.seenList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                    try await listManager.removeFromList(listId: listManager.seenList.id, itemId: item.id)
                    EpisodeSeenManager.shared.unmarkShowSeen(showId: tvShow.id)
                }
            } else {
                try await listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: .tv)
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Seen")
        }
    }
    
    private func handleLikedTap(tvShow: TVShow, movie: Movie) async {
        do {
            let isCurrentlyLiked = listManager.isInList(listId: listManager.likedList.id, mediaId: tvShow.id, mediaType: .tv)
            let isCurrentlyDisliked = listManager.isInList(listId: listManager.dislikedList.id, mediaId: tvShow.id, mediaType: .tv)
            
            if isCurrentlyLiked {
                // Remove like
                if let item = listManager.likedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                    try await listManager.removeFromList(listId: listManager.likedList.id, itemId: item.id)
                    // Update reaction counts: remove like
                    try await MovieReactionService.shared.updateReactionCounts(
                        mediaId: tvShow.id,
                        mediaType: .tv,
                        oldReaction: .like,
                        newReaction: nil
                    )
                }
            } else {
                // Remove dislike if exists
                if let dislikedItem = listManager.dislikedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                    try await listManager.removeFromList(listId: listManager.dislikedList.id, itemId: dislikedItem.id)
                }
                // Add like
                try await listManager.addToList(listId: listManager.likedList.id, movie: movie, mediaType: .tv)
                // Update reaction counts: change from dislike to like (or none to like)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: tvShow.id,
                    mediaType: .tv,
                    oldReaction: isCurrentlyDisliked ? .dislike : nil,
                    newReaction: .like
                )
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Liked")
        }
    }
    
    private func handleDislikedTap(tvShow: TVShow, movie: Movie) async {
        do {
            let isCurrentlyLiked = listManager.isInList(listId: listManager.likedList.id, mediaId: tvShow.id, mediaType: .tv)
            let isCurrentlyDisliked = listManager.isInList(listId: listManager.dislikedList.id, mediaId: tvShow.id, mediaType: .tv)
            
            if isCurrentlyDisliked {
                // Remove dislike
                if let item = listManager.dislikedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                    try await listManager.removeFromList(listId: listManager.dislikedList.id, itemId: item.id)
                    // Update reaction counts: remove dislike
                    try await MovieReactionService.shared.updateReactionCounts(
                        mediaId: tvShow.id,
                        mediaType: .tv,
                        oldReaction: .dislike,
                        newReaction: nil
                    )
                }
            } else {
                // Remove like if exists
                if let likedItem = listManager.likedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                    try await listManager.removeFromList(listId: listManager.likedList.id, itemId: likedItem.id)
                }
                // Add dislike
                try await listManager.addToList(listId: listManager.dislikedList.id, movie: movie, mediaType: .tv)
                // Update reaction counts: change from like to dislike (or none to dislike)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: tvShow.id,
                    mediaType: .tv,
                    oldReaction: isCurrentlyLiked ? .like : nil,
                    newReaction: .dislike
                )
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Disliked")
        }
    }
    
    // MARK: - Sharing
    
    private func handleShare(tvShow: TVShow) async {
        isPreparingShare = true
        await prepareShareItems(tvShow: tvShow)
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
    
    private func prepareShareItems(tvShow: TVShow) async {
        var items: [Any] = []
        
        if let posterPath = tvShow.posterPath {
            let posterURLString = "https://image.tmdb.org/t/p/w500\(posterPath)"
            if let url = URL(string: posterURLString) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = UIImage(data: data) {
                        items.append(image)
                    }
                } catch {
                    // silently ignore for sharing
                }
            }
        }
        
        var text = "Check out \(tvShow.name)"
        if let year = tvShow.year {
            text += " (\(year))"
        }
        if !tvShow.overview.isEmpty {
            text += "\n\n\(tvShow.overview)"
        }
        items.append(text)
        
        await MainActor.run {
            shareItems = items
        }
    }
    
    private func handleWhyForMeTap() {
        guard appState.isAuthenticated else {
            showAuthGate = true
            return
        }

        if !AITokenManager.shared.canMakeRequest() {
            if !quotaManager.isProUser {
                showAIPaywall = true
            }
            return
        }

        showWhyForMeSheet = true
        if viewModel.whyForMeMessage?.isEmpty != false {
            Task { await viewModel.generateWhyForMe() }
        }
    }
}

struct TVShowDetailHeaderView: View {
    let tvShow: TVShow
    let onDismiss: () -> Void
    let onSearch: () -> Void
    let onShare: () -> Void
    
    var body: some View {
        ZStack(alignment: .top) {
            CachedAsyncImage(url: tvShow.backdropURL)
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
                
                Text(tvShow.name)
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

struct TVShowInfoSection: View {
    let tvShow: TVShow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Metadata row: seasons · year range | rating% (n ratings)
            HStack(spacing: 0) {
                if let count = tvShow.numberOfSeasons {
                    Text("\(count) \(count == 1 ? "season" : "seasons")")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)

                    if let range = tvShow.airYearRange {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 3))
                            .foregroundColor(Color.white.opacity(0.4))
                            .padding(.horizontal, 6)
                        Text(range)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                } else if let range = tvShow.airYearRange {
                    Text(range)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 10)

                HStack(spacing: 4) {
                    Text("\(tvShow.ratingPercentage)%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                    Text("(\(tvShow.voteCount) \("movieDetail.ratings".localized))")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
            }

            Text(tvShow.name)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.theme.textPrimary)

            if !tvShow.overview.isEmpty {
                Text(tvShow.overview)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

struct TVShowCreditsSection: View {
    let director: Crew?
    let cast: [Cast]
    let tvShow: TVShow
    let onActorTap: (Cast) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("movieDetail.information".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)

                VStack(alignment: .leading, spacing: 12) {
                    if tvShow.ratingPercentage > 0 {
                        InfoRow(title: "movieDetail.rating".localized, value: "\(tvShow.ratingPercentage)%")
                    }

                    if let genres = tvShow.genres, !genres.isEmpty {
                        InfoRow(title: "movieDetail.genres".localized, value: genres.map { $0.name }.joined(separator: ", "))
                    }

                    if let runtime = tvShow.formattedEpisodeRuntime {
                        InfoRow(title: "movieDetail.runtime".localized, value: runtime)
                    }

                    if let countries = tvShow.productionCountries, !countries.isEmpty {
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

struct SimilarTVShowsSection: View {
    let tvShows: [TVShow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("movieDetail.similar".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(tvShows) { show in
                        NavigationLink(destination: TVShowDetailView(tvShowId: show.id)) {
                            TVShowCard(tvShow: show)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct TVShowCard: View {
    let tvShow: TVShow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: tvShow.posterURL, maxPixelSize: 630)
                .aspectRatio(contentMode: .fill)
                .frame(width: 140, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(tvShow.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)
                .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.theme.accentOrange)
                Text(tvShow.rating)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
        }
    }
}

// MARK: - Seasons Carousel

struct SeasonsCarouselSection: View {
    let seasons: [Season]
    let showId: Int
    let showName: String
    let showBackdropPath: String?
    let showPosterPath: String?
    let tvShow: TVShow?
    let cast: [Cast]
    let director: Crew?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(seasons) { season in
                        NavigationLink(destination: SeasonDetailView(
                            showId: showId,
                            seasonNumber: season.seasonNumber,
                            showName: showName,
                            showBackdropPath: showBackdropPath,
                            showPosterPath: showPosterPath,
                            tvShow: tvShow,
                            cast: cast,
                            director: director
                        )) {
                            SeasonCard(season: season)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Mark All Seen Confirmation

struct MarkAllSeenConfirmationSheet: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("tvDetail.markAllSeenTitle".localized)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("tvDetail.markAllSeenDescription".localized)
                    .font(.system(size: 15))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Text("tvDetail.markAllSeenQuestion".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("tvDetail.markAllSeenConfirm".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.theme.accentOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onCancel) {
                    Text("tvDetail.markAllSeenCancel".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SeasonCard: View {
    let season: Season

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if let url = season.posterURL {
                    CachedAsyncImage(url: url, maxPixelSize: 630)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.theme.cardBackground)
                        .frame(width: 140, height: 210)
                        .overlay {
                            Image(systemName: "tv")
                                .font(.system(size: 32))
                                .foregroundColor(.theme.textSecondary.opacity(0.5))
                        }
                }

                Text("S\(season.seasonNumber)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.theme.accentOrange.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }

            Text(season.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text("\(season.episodeCount) episodes")
                .font(.system(size: 11))
                .foregroundColor(.theme.textSecondary)
                .frame(width: 140, alignment: .leading)
        }
    }
}
