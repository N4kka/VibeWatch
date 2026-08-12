import SwiftUI
import YouTubeiOSPlayerHelper
import UIKit

struct MovieDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @StateObject private var viewModel: MovieDetailViewModel
    @StateObject private var listManager = ListManager.shared
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
    
    init(movieId: Int) {
        _viewModel = StateObject(wrappedValue: MovieDetailViewModel(movieId: movieId))
    }
    
    private var shouldShowAd: Bool {
        !quotaManager.isProUser
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.isLoading {
                        MediaDetailSkeletonView()
                    } else if let error = viewModel.error {
                        errorView(error)
                    } else if let movie = viewModel.movie {
                        MediaDetailHero(
                            backdropURL: movie.backdropURL,
                            title: movie.title,
                            year: movie.year,
                            runtime: movie.formattedRuntime,
                            genres: movie.genres?.map(\.name) ?? [],
                            rating: movie.rating,
                            voteCount: movie.voteCount,
                            affinityPercent: movie.ratingPercentage,
                            onBack: { dismiss() },
                            onShare: { Task { await handleShare(movie: movie) } }
                        )

                        // Il margine sta sui singoli blocchi, non sul contenitore: le sezioni con
                        // carosello portano già il proprio, e sommarli le rientrava del doppio.
                        VStack(alignment: .leading, spacing: 20) {
                            MediaProviderDisclosure(
                                providerState: viewModel.watchProviderState,
                                title: movie.title,
                                mediaType: .movie,
                                movie: movie
                            )
                            .padding(.horizontal, 20)

                            MediaDetailActionStrip(
                                mediaId: movie.id,
                                mediaType: .movie,
                                onWatchlist: { Task { await handleWatchlistTap(movie: movie) } },
                                onSeen: { Task { await handleSeenTap(movie: movie) } },
                                onLiked: { Task { await handleLikedTap(movie: movie) } },
                                onList: { showSavePanel = true }
                            )
                            .padding(.horizontal, 20)

                            if !movie.overview.isEmpty {
                                Text(movie.overview)
                                    .font(.system(size: 14))
                                    .foregroundColor(.theme.textSecondary)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 20)
                            }

                            MediaRatingFavoriteCard(mediaType: "movie", tmdbId: movie.id)
                                .padding(.horizontal, 20)

                            MediaWhyForMeCard { handleWhyForMeTap() }
                                .padding(.horizontal, 20)

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
            await viewModel.loadMovieDetails()
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
                previousTitle: viewModel.movie?.title ?? ""
            )
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
                affinityPercent: viewModel.movie?.ratingPercentage ?? 0,
                analysis: viewModel.whyForMeAnalysis,
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
    
    // Action Handlers

    private func handleWatchlistTap(movie: Movie) async {
        let wasActive = listManager.isInList(
            listId: listManager.watchlist.id,
            mediaId: movie.id,
            mediaType: .movie
        )
        await runWithFeedback(.watchlist, willBeActive: !wasActive, context: "Toggle Watchlist") {
            if wasActive,
               let item = listManager.watchlist.items.first(where: {
                   $0.mediaId == movie.id && $0.mediaType == .movie
               }) {
                try await listManager.removeFromList(listId: listManager.watchlist.id, itemId: item.id)
            } else if !wasActive {
                try await listManager.addToList(listId: listManager.watchlist.id, movie: movie, mediaType: .movie)
            }
        }
    }
    
    private func handleSeenTap(movie: Movie) async {
        let wasActive = listManager.isInList(listId: listManager.seenList.id, mediaId: movie.id, mediaType: .movie)
        await runWithFeedback(.seen, willBeActive: !wasActive, context: "Toggle Seen") {
            if wasActive {
                if let item = listManager.seenList.items.first(where: { $0.mediaId == movie.id && $0.mediaType == .movie }) {
                    try await listManager.removeFromList(listId: listManager.seenList.id, itemId: item.id)
                }
            } else {
                try await listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: .movie)
            }
        }
    }

    private func handleWhyForMeTap() {
        guard appState.isAuthenticated else {
            showAuthGate = true
            return
        }

        guard AITokenManager.shared.canMakeRequest() else {
            if !quotaManager.isProUser { showAIPaywall = true }
            return
        }

        showWhyForMeSheet = true
        if viewModel.whyForMeAnalysis == nil {
            Task { await viewModel.generateWhyForMe() }
        }
    }
    
    private func handleLikedTap(movie: Movie) async {
        let isCurrentlyLiked = listManager.isInList(listId: listManager.likedList.id, mediaId: movie.id, mediaType: .movie)
        let isCurrentlyDisliked = listManager.isInList(listId: listManager.dislikedList.id, mediaId: movie.id, mediaType: .movie)

        await runWithFeedback(.liked, willBeActive: !isCurrentlyLiked, context: "Toggle Liked") {
            if isCurrentlyLiked {
                if let item = listManager.likedList.items.first(where: { $0.mediaId == movie.id && $0.mediaType == .movie }) {
                    try await listManager.removeFromList(listId: listManager.likedList.id, itemId: item.id)
                    try await MovieReactionService.shared.updateReactionCounts(
                        mediaId: movie.id, mediaType: .movie, oldReaction: .like, newReaction: nil
                    )
                }
            } else {
                if let dislikedItem = listManager.dislikedList.items.first(where: { $0.mediaId == movie.id && $0.mediaType == .movie }) {
                    try await listManager.removeFromList(listId: listManager.dislikedList.id, itemId: dislikedItem.id)
                }
                try await listManager.addToList(listId: listManager.likedList.id, movie: movie, mediaType: .movie)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: movie.id, mediaType: .movie,
                    oldReaction: isCurrentlyDisliked ? .dislike : nil, newReaction: .like
                )
            }
        }
    }

    /// Avvolge la mutazione nel ciclo del toast: fase in corso mentre l'operazione gira, poi
    /// l'esito. Prima partiva un toast già terminale e la barra di avanzamento non si vedeva mai.
    private func runWithFeedback(
        _ action: MediaDetailFeedback.Action,
        willBeActive: Bool,
        context: String,
        _ operation: () async throws -> Void
    ) async {
        let toastId = ToastCenter.shared.begin(
            message: MediaDetailFeedback.progressKey(for: action, isActive: willBeActive).localized
        )
        do {
            try await operation()
            ToastCenter.shared.complete(
                toastId,
                message: MediaDetailFeedback.messageKey(for: action, isActive: willBeActive).localized
            )
        } catch {
            ToastCenter.shared.fail(toastId, message: "common.pleaseTryAgain".localized)
            ErrorHandler.shared.handle(error, context: context)
        }
    }
    
    private func handleDislikedTap(movie: Movie) async {
        let isCurrentlyLiked = listManager.isInList(listId: listManager.likedList.id, mediaId: movie.id, mediaType: .movie)
        let isCurrentlyDisliked = listManager.isInList(listId: listManager.dislikedList.id, mediaId: movie.id, mediaType: .movie)

        await runWithFeedback(.disliked, willBeActive: !isCurrentlyDisliked, context: "Toggle Disliked") {
            if isCurrentlyDisliked {
                if let item = listManager.dislikedList.items.first(where: { $0.mediaId == movie.id && $0.mediaType == .movie }) {
                    try await listManager.removeFromList(listId: listManager.dislikedList.id, itemId: item.id)
                    try await MovieReactionService.shared.updateReactionCounts(
                        mediaId: movie.id, mediaType: .movie, oldReaction: .dislike, newReaction: nil
                    )
                }
            } else {
                if let likedItem = listManager.likedList.items.first(where: { $0.mediaId == movie.id && $0.mediaType == .movie }) {
                    try await listManager.removeFromList(listId: listManager.likedList.id, itemId: likedItem.id)
                }
                try await listManager.addToList(listId: listManager.dislikedList.id, movie: movie, mediaType: .movie)
                try await MovieReactionService.shared.updateReactionCounts(
                    mediaId: movie.id, mediaType: .movie,
                    oldReaction: isCurrentlyLiked ? .like : nil, newReaction: .dislike
                )
            }
        }
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
        if let url = MoviePosterShareURLBuilder.url(posterPath: movie.posterPath),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let image = UIImage(data: data) {
            items.append(image)
        }
        items.append(MovieShareTextBuilder.text(title: movie.title, year: movie.year, overview: movie.overview))
        await MainActor.run { shareItems = items }
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
    @StateObject private var listManager = ListManager.shared
    
    let movie: Movie
    let mediaType: MediaType
    let onSaveTap: () -> Void
    let onSeenTap: () -> Void
    let onLikedTap: () -> Void
    let onDislikedTap: () -> Void
    
    private var actionState: MovieActionButtonStateBuilder.State {
        MovieActionButtonStateBuilder.state(
            mediaId: movie.id,
            mediaType: mediaType,
            lists: listManager.lists,
            seenList: listManager.seenList,
            likedList: listManager.likedList,
            dislikedList: listManager.dislikedList
        )
    }
    
    var body: some View {
        let state = actionState

        HStack(spacing: 12) {
            ActionButton(
                icon: "bookmark.fill",
                title: "movieDetail.save".localized,
                isActive: state.isInAnyList
            ) {
                onSaveTap()
            }
            
            ActionButton(
                icon: "eye.fill",
                title: "movieDetail.seen".localized,
                isActive: state.isInSeen
            ) {
                withAnimation {
                    onSeenTap()
                }
            }
            
            ActionButton(
                icon: "hand.thumbsup.fill",
                title: "",
                isActive: state.isInLiked,
                count: state.likesCount
            ) {
                withAnimation {
                    onLikedTap()
                }
            }
            
            ActionButton(
                icon: "hand.thumbsdown.fill",
                title: "",
                isActive: state.isInDisliked,
                count: state.dislikesCount
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
                        CachedAsyncImage(url: trailer.thumbnailURL, maxPixelSize: 600)
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var aiTokenManager = AITokenManager.shared
    let title: String
    let affinityPercent: Int
    let analysis: WhyForMeAnalysis?
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void

    @State private var feedback: Bool?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 42, height: 5)
                .padding(.top, 10)

            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                Text("mediaDetail.why.title".localized)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                Group {
                    if isLoading {
                        loadingContent
                    } else if let error, !error.isEmpty {
                        errorContent(error)
                    } else if let analysis {
                        loadedContent(analysis)
                    } else {
                        loadingContent
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .presentationDetents([.fraction(0.84), .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(hex: "16171c"))
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 17)
                    .fill(Color.white.opacity(0.045))
                    .frame(height: index == 0 ? 88 : 108)
            }
        }
        .redacted(reason: .placeholder)
    }

    private func loadedContent(_ analysis: WhyForMeAnalysis) -> some View {
        let presentation = WhyForMePresentation.make(
            analysis: analysis,
            affinityPercent: affinityPercent
        )
        return VStack(spacing: 12) {
            HStack(spacing: 15) {
                Text("\(presentation.affinityPercent)%")
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundColor(.theme.accentOrange)
                VStack(alignment: .leading, spacing: 9) {
                    Text("mediaDetail.why.affinity".localized)
                        .font(.system(size: 14.5, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.13))
                            Capsule().fill(Color.theme.accentOrange)
                                .frame(width: geometry.size.width * CGFloat(presentation.affinityPercent) / 100)
                        }
                    }
                    .frame(height: 6)
                }
            }
            .padding(16)
            .background(Color.theme.accentOrange.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(Color.theme.accentOrange.opacity(0.55), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 17))

            ForEach(Array(presentation.reasons.enumerated()), id: \.offset) { index, reason in
                reasonCard(index: index, reason: reason)
            }

            HStack {
                Text("mediaDetail.why.helpful".localized)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.theme.textSecondary)
                feedbackButton(icon: "hand.thumbsup", value: true)
                feedbackButton(icon: "hand.thumbsdown", value: false)
                Spacer()
                Button(action: onRetry) {
                    Label("mediaDetail.why.regenerate".localized, systemImage: "arrow.clockwise")
                        .font(.system(size: 13.5, weight: .heavy))
                        .foregroundColor(.theme.accentOrange)
                }
            }
            .padding(.top, 5)

            Text(String(
                format: "mediaDetail.why.quota".localized,
                aiTokenManager.requestsUsedToday,
                aiTokenManager.dailyLimit
            ))
            .font(.system(size: 11.5))
            .foregroundColor(Color(hex: "6f7077"))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reasonCard(index: Int, reason: WhyForMePresentation.Reason) -> some View {
        let icons = ["heart", "chart.bar", "person"]
        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: icons[index % icons.count])
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.theme.accentOrange)
                .frame(width: 42, height: 42)
                .background(Color.theme.accentOrange.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(reason.titleKey.localized)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Text(reason.body)
                    .font(.system(size: 13.5))
                    .foregroundColor(.theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 17))
    }

    private func feedbackButton(icon: String, value: Bool) -> some View {
        Button { feedback = value } label: {
            Image(systemName: feedback == value ? "\(icon).fill" : icon)
                .font(.system(size: 14))
                .foregroundColor(feedback == value ? .theme.accentOrange : .theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
        }
    }

    private func errorContent(_ error: String) -> some View {
        VStack(spacing: 16) {
            Text(error)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("common.tryAgain".localized, action: onRetry)
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(.theme.accentOrange)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 17))
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
                    ForEach(MovieCreditsInfoBuilder.rows(movie: movie, director: director), id: \.titleKey) { row in
                        InfoRow(title: row.titleKey.localized, value: row.value, isItalic: row.isItalic)
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
                        // Pigro: il cast completo di una serie lunga sono centinaia di schede.
                        LazyHStack(spacing: 12) {
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
    var isItalic: Bool = false
    
    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14))
                .italic(isItalic)
                .foregroundColor(isItalic ? .theme.textSecondary : .theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            
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
                CachedAsyncImage(url: actor.profileURL, maxPixelSize: 240)
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
