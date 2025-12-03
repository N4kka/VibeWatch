import SwiftUI
import YouTubeiOSPlayerHelper

struct MovieDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: MovieDetailViewModel
    @StateObject private var listManager = ListManager.shared
    @State private var showSavePanel = false
    @State private var showAuthGate = false
    @State private var showSearch = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    
    init(movieId: Int) {
        _viewModel = StateObject(wrappedValue: MovieDetailViewModel(movieId: movieId))
    }
    
    var body: some View {
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
                            movie: movie,
                            mediaType: .movie,
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
                        
                        if let providers = viewModel.watchProviders {
                            WatchNowSection(providers: providers, mediaType: .movie, title: movie.title, year: movie.year, imdbId: viewModel.imdbId)
                        }
                        
                        if let trailer = viewModel.trailer {
                            TrailerSection(trailer: trailer)
                        }
                        
                        if !viewModel.mainCast.isEmpty || viewModel.director != nil {
                            MovieCreditsSection(
                                director: viewModel.director,
                                cast: viewModel.mainCast,
                                movie: movie
                            )
                        }
                        
                        if !viewModel.similarMovies.isEmpty {
                            SimilarMoviesSection(movies: viewModel.similarMovies)
                        }
                    }
                    .padding(.horizontal, 50)
                    .padding(.bottom, 40)
                }
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
            SearchView()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
                .onDisappear {
                    shareItems = []
                }
        }
        .fullScreenCover(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
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
    
    private func handleSeenTap(movie: Movie) async {
        do {
            if listManager.isInList(listId: listManager.seenList.id, mediaId: movie.id, mediaType: .movie) {
                if let item = listManager.seenList.items.first(where: { $0.mediaId == movie.id && $0.mediaType == .movie }) {
                    try await listManager.removeFromList(listId: listManager.seenList.id, itemId: item.id)
                }
            } else {
                try await listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: .movie)
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Seen")
        }
    }
    
    private func handleLikedTap(movie: Movie) async {
        do {
            let isCurrentlyLiked = listManager.isInList(listId: listManager.likedList.id, mediaId: movie.id, mediaType: .movie)
            let isCurrentlyDisliked = listManager.isInList(listId: listManager.dislikedList.id, mediaId: movie.id, mediaType: .movie)
            
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
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Liked")
        }
    }
    
    private func handleDislikedTap(movie: Movie) async {
        do {
            let isCurrentlyLiked = listManager.isInList(listId: listManager.likedList.id, mediaId: movie.id, mediaType: .movie)
            let isCurrentlyDisliked = listManager.isInList(listId: listManager.dislikedList.id, mediaId: movie.id, mediaType: .movie)
            
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
        } catch {
            ErrorHandler.shared.handle(error, context: "Toggle Disliked")
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
    
    private var isInAnyList: Bool {
        listManager.lists.contains { list in
            list.items.contains { $0.mediaId == movie.id && $0.mediaType == mediaType }
        }
    }
    
    private var isInSeen: Bool {
        listManager.isInList(listId: listManager.seenList.id, mediaId: movie.id, mediaType: mediaType)
    }
    
    private var isInLiked: Bool {
        listManager.isInList(listId: listManager.likedList.id, mediaId: movie.id, mediaType: mediaType)
    }
    
    private var isInDisliked: Bool {
        listManager.isInList(listId: listManager.dislikedList.id, mediaId: movie.id, mediaType: mediaType)
    }
    
    private var likesCount: Int {
        listManager.likedList.items.filter { $0.mediaId == movie.id && $0.mediaType == mediaType }.count
    }
    
    private var dislikesCount: Int {
        listManager.dislikedList.items.filter { $0.mediaId == movie.id && $0.mediaType == mediaType }.count
    }
    
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

struct WatchNowSection: View {
    let providers: CountryProviders
    let mediaType: MediaType
    let title: String
    let year: String?
    let imdbId: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("movieDetail.watchNow".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if let flatrate = providers.flatrate, !flatrate.isEmpty {
                ProviderGroup(title: "platforms.streaming".localized, providers: flatrate, justWatchLink: providers.link, mediaTitle: title)
            }
            
            if let rent = providers.rent, !rent.isEmpty {
                ProviderGroup(title: "platforms.rent".localized, providers: rent, justWatchLink: providers.link, mediaTitle: title)
            }
            
            if let buy = providers.buy, !buy.isEmpty {
                ProviderGroup(title: "platforms.buy".localized, providers: buy, justWatchLink: providers.link, mediaTitle: title)
            }
            
            Button {
                // TODO: Report issue
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
    }
}

struct ProviderGroup: View {
    let title: String
    let providers: [Provider]
    let justWatchLink: String?
    let mediaTitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 80), spacing: 16)
            ], spacing: 16) {
                ForEach(providers) { (provider: Provider) in
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
    
    class Coordinator: NSObject, YTPlayerViewDelegate {
        var loadedVideoId: String?
        
        func playerViewDidBecomeReady(_ playerView: YTPlayerView) {
            playerView.playVideo()
        }
    }
}

struct MovieCreditsSection: View {
    let director: Crew?
    let cast: [Cast]
    let movie: Movie
    
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
                                CastMemberCard(actor: actor)
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
    
    var body: some View {
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
                            MediaCard(movie: movie)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
