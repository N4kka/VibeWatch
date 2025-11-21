import SwiftUI
import WebKit

struct TVShowDetailView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: TVShowDetailViewModel
    @StateObject private var listManager = ListManager.shared
    @State private var showSavePanel = false
    @State private var showSearch = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    
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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let tvShow = viewModel.tvShow {
                    let tvShowMovie = tvShowToMovie(tvShow)
                    
                    headerView(tvShow: tvShow)
                    
                    VStack(spacing: 24) {
                        infoView(tvShow: tvShow)
                        actionsView(tvShow: tvShow, movie: tvShowMovie)
                        providersView
                        trailerView
                        creditsView(tvShow: tvShow)
                        similarView
                    }
                    .padding(.horizontal, 50)
                    .padding(.bottom, 40)
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                }
            }
        }
        .background(Color.theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 100 && abs(value.translation.height) < 50 {
                        dismiss()
                    }
                }
        )
        .sheet(isPresented: $showSavePanel) {
            if let tvShow = viewModel.tvShow {
                SaveToListPanel(movie: tvShowToMovie(tvShow), mediaType: .tv)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .task {
            await viewModel.loadTVShowDetails()
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
    
    // MARK: - Subviews (computed)
    
    private func headerView(tvShow: TVShow) -> some View {
        TVShowDetailHeaderView(
            tvShow: tvShow,
            onDismiss: { dismiss() },
            onSearch: { showSearch = true },
            onShare: {
                Task { await handleShare(tvShow: tvShow) }
            }
        )
    }
    
    private func infoView(tvShow: TVShow) -> some View {
        TVShowInfoSection(tvShow: tvShow)
    }
    
    private func actionsView(tvShow: TVShow, movie: Movie) -> some View {
        ActionButtonsSection(
            movie: movie,
            mediaType: .tv,
            onSaveTap: { showSavePanel = true },
            onSeenTap: { handleSeenTap(tvShow: tvShow, movie: movie) },
            onLikedTap: { handleLikedTap(tvShow: tvShow, movie: movie) },
            onDislikedTap: { handleDislikedTap(tvShow: tvShow, movie: movie) }
        )
    }
    
    @ViewBuilder
    private var providersView: some View {
        if let providers = viewModel.watchProviders, let tvShow = viewModel.tvShow {
            WatchNowSection(providers: providers, mediaType: .tv, title: tvShow.name, year: tvShow.year, imdbId: viewModel.imdbId)
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
        if !viewModel.mainCast.isEmpty {
            TVShowCreditsSection(
                cast: viewModel.mainCast,
                tvShow: tvShow
            )
        }
    }
    
    @ViewBuilder
    private var similarView: some View {
        if !viewModel.similarShows.isEmpty {
            SimilarTVShowsSection(tvShows: viewModel.similarShows)
        }
    }
    
    // MARK: - Actions
    
    private func handleSeenTap(tvShow: TVShow, movie: Movie) {
        if listManager.isInList(listId: listManager.seenList.id, mediaId: tvShow.id, mediaType: .tv) {
            if let item = listManager.seenList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                listManager.removeFromList(listId: listManager.seenList.id, itemId: item.id)
            }
        } else {
            listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: .tv)
        }
    }
    
    private func handleLikedTap(tvShow: TVShow, movie: Movie) {
        if listManager.isInList(listId: listManager.likedList.id, mediaId: tvShow.id, mediaType: .tv) {
            if let item = listManager.likedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                listManager.removeFromList(listId: listManager.likedList.id, itemId: item.id)
            }
        } else {
            if let dislikedItem = listManager.dislikedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                listManager.removeFromList(listId: listManager.dislikedList.id, itemId: dislikedItem.id)
            }
            listManager.addToList(listId: listManager.likedList.id, movie: movie, mediaType: .tv)
        }
    }
    
    private func handleDislikedTap(tvShow: TVShow, movie: Movie) {
        if listManager.isInList(listId: listManager.dislikedList.id, mediaId: tvShow.id, mediaType: .tv) {
            if let item = listManager.dislikedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                listManager.removeFromList(listId: listManager.dislikedList.id, itemId: item.id)
            }
        } else {
            if let likedItem = listManager.likedList.items.first(where: { $0.mediaId == tvShow.id && $0.mediaType == .tv }) {
                listManager.removeFromList(listId: listManager.likedList.id, itemId: likedItem.id)
            }
            listManager.addToList(listId: listManager.dislikedList.id, movie: movie, mediaType: .tv)
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
}

struct TVShowDetailHeaderView: View {
    let tvShow: TVShow
    let onDismiss: () -> Void
    let onSearch: () -> Void
    let onShare: () -> Void
    
    var body: some View {
        ZStack(alignment: .top) {
            AsyncImageView(url: tvShow.backdropURL, contentMode: .fill)
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
            HStack(spacing: 16) {
                if let year = tvShow.year {
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                
                HStack(spacing: 4) {
                    Text("\(Int(tvShow.voteAverage * 10))%")
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
    let cast: [Cast]
    let tvShow: TVShow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("movieDetail.information".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(title: "Rating", value: "\(Int(tvShow.voteAverage * 10))%")
                    
                    if let genres = tvShow.genres, !genres.isEmpty {
                        InfoRow(title: "Genres", value: genres.map { $0.name }.joined(separator: ", "))
                    }
                    
                    if let countries = tvShow.productionCountries, !countries.isEmpty {
                        InfoRow(title: "Country", value: countries.first?.name ?? "")
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
                        TVShowCard(tvShow: show)
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
            AsyncImageView(url: tvShow.posterURL, contentMode: .fill)
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
