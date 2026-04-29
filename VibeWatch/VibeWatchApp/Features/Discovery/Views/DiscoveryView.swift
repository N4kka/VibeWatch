import SwiftUI

struct DiscoveryView: View {
    @Environment(\.discoveryRepository) private var discoveryRepository
    @EnvironmentObject private var appState: AppState
    @Binding private var selectedMovie: Movie?
    @Binding private var selectedMediaType: MediaType

    init(selectedMovie: Binding<Movie?>, selectedMediaType: Binding<MediaType>) {
        _selectedMovie = selectedMovie
        _selectedMediaType = selectedMediaType
    }

    var body: some View {
        DiscoveryContentView(
            repository: discoveryRepository,
            userId: appState.currentUser?.id ?? "anonymous",
            selectedMovie: $selectedMovie,
            selectedMediaType: $selectedMediaType
        )
        .id(appState.currentUser?.id ?? "anonymous")
    }
}

private struct DiscoveryContentView: View {
    @State private var viewModel: DiscoveryViewModel
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var gamificationService = GamificationService.shared
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @ObservedObject var localizationManager = LocalizationManager.shared
    @State private var showProfile = false
    @State private var showSearch = false
    @State private var showFilters = false
    @Binding var selectedMovie: Movie?
    @Binding var selectedMediaType: MediaType
    @State private var scrollPosition: String? = nil
    @State private var moodCarouselIndex = 0
    @State private var lastTappedMovieId: Int? = nil
    @State private var hasRestoredScroll = false
    @State private var filterSessionId = UUID().uuidString

    init(
        repository: any DiscoveryRepository,
        userId: String,
        selectedMovie: Binding<Movie?>,
        selectedMediaType: Binding<MediaType>
    ) {
        _viewModel = State(initialValue: DiscoveryViewModel(repository: repository, userId: userId))
        _selectedMovie = selectedMovie
        _selectedMediaType = selectedMediaType
    }

    var body: some View {
        ZStack {
            if viewModel.isLoading && viewModel.hasNoContent {
                ProgressView()
            } else if let error = viewModel.error, viewModel.hasNoContent {
                errorView(error)
            } else {
                discoveryMainView
            }

            // Floating XP Badge (gamification)
            if gamificationService.isLoaded {
                FloatingXPBadgeView(gamificationService: gamificationService)
            }
        }
        .background(Color.theme.background.ignoresSafeArea())
        .task {
            await viewModel.loadContentIfNeeded()

            // Load gamification state
            if let userId = appState.currentUser?.id {
                await gamificationService.loadUserState(userId: userId)

                // Only award and show XP if this is first launch of day
                let isPro = quotaManager.isProUser
                let today = Calendar.current.startOfDay(for: Date())
                let lastActivity = gamificationService.userState.lastActivityDate

                let isFirstLaunchOfDay = lastActivity == nil ||
                    Calendar.current.startOfDay(for: lastActivity!) < today

                if isFirstLaunchOfDay {
                    _ = await gamificationService.awardXP(userId: userId, action: .dailyOpen, isPro: isPro)
                }
                // If not first launch, don't call awardXP at all - no toast will show
            }

            // Analytics: Track screen view
            AnalyticsService.shared.logScreenView(screenName: "Discovery", screenClass: "DiscoveryView")

            // Debug: Print reaction counts
            await SQLiteService.shared.debugPrintReactionCounts()
        }
        .onChange(of: localizationManager.localeDidChange) {_, _ in
            // Reload content when language/country changes
            Task {
                await viewModel.loadContent(forceRefresh: true)
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView(viewModel: searchViewModel)
        }
        .overlay {
            if showFilters {
                GlobalFilterView(
                    filters: $viewModel.globalFilters,
                    isPresented: $showFilters
                ) { filters in
                    viewModel.applyFilters(filters)
                    AnalyticsService.shared.logFilterApplied(
                        filterType: "global",
                        value: filters.isActive ? "active" : "cleared",
                        context: AnalyticsContext(
                            source: "discovery_filters",
                            sessionId: filterSessionId
                        ),
                        extra: [
                            "filter_active": filters.isActive,
                            "active_filter_count": filters.activeFilterCount
                        ]
                    )
                }
                .transition(.opacity)
            }
        }
        .toast(isShowing: $appState.showSuccessToast, message: appState.toastMessage, type: .success)
        .toast(isShowing: $appState.showErrorToast, message: appState.toastMessage, type: .error)
        .xpToast(gamificationService: gamificationService)
        .onChange(of: appState.shouldShowSignIn) {_, newValue in
            if newValue {
                print("🔄 [DiscoveryView] Redirecting to Sign In via Profile")
                showProfile = true
                // Note: ProfileView will observe this same flag and open the SignIn sheet
            }
        }
    }
    
    private func errorView(_ error: AppError) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(error.errorDescription ?? "error.oops".localized)
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
                    await viewModel.loadDiscoveryContent()
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
    }
    
    private var discoveryMainView: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 32) {
                        DiscoveryHeaderView(
                        onSearchTap: { showSearch = true },
                        onFilterTap: {
                            filterSessionId = UUID().uuidString
                            showFilters = true
                        },
                        onProfileTap: { showProfile = true },
                        avatarURL: appState.currentUser?.avatarURL,
                        isProUser: quotaManager.isProUser,
                        activeFilterCount: viewModel.globalFilters.activeFilterCount
                    )
                    .padding(.top, 4)
                    .id("header")
                    
                        ForEach(viewModel.personalizedCarousels, id: \.type.rawValue) { carousel in
                            if carousel.type == .dailyMix {
                                MoodCarouselSection(
                                    movies: carousel.items,
                                    descriptions: carousel.descriptions,
                                    currentIndex: $moodCarouselIndex
                                ) { movie in
                                    scrollPosition = carousel.type.rawValue
                                    viewModel.recordCarouselClick(movie: movie, carouselType: carousel.type, mediaType: .movie)
                                    selectedMovie = movie
                                    selectedMediaType = .movie
                                }
                                .id(carousel.type.rawValue)
                            } else {
                                MediaSection(
                                    title: carousel.title,
                                    items: carousel.items,
                                    descriptions: carousel.descriptions,
                                    type: mediaType(for: carousel.type),
                                    scrollToMovieId: scrollPosition == carousel.type.rawValue ? lastTappedMovieId : nil
                                ) { movie in
                                    scrollPosition = carousel.type.rawValue
                                    lastTappedMovieId = movie.id
                                    let mediaType = mediaType(for: carousel.type)
                                    viewModel.recordCarouselClick(movie: movie, carouselType: carousel.type, mediaType: mediaType)
                                    selectedMovie = movie
                                    selectedMediaType = mediaType
                                }
                                .id(carousel.type.rawValue)
                            }
                        }
                    
                        Color.clear
                            .frame(height: 80)
                    }
                }
                .id(viewModel.refreshToken)
                .refreshable {
                    // Force refresh from TMDB to get latest content and reload images
                    print("🔄 [DiscoveryView] Pull-to-refresh triggered")
                    await viewModel.refreshContent()
                }
                .background(Color.theme.background.ignoresSafeArea())
                .opacity(hasRestoredScroll || scrollPosition == nil ? 1 : 0)
                .onAppear {
                    restoreScrollIfNeeded(proxy: proxy)
                }
                .onChange(of: viewModel.personalizedCarousels.map { $0.type.rawValue }.joined(separator: "|")) { _, _ in
                    restoreScrollIfNeeded(proxy: proxy)
                }
                .onChange(of: selectedMovie) {_, newValue in
                    // Reset flag when navigating away so we can restore again
                    if newValue != nil {
                        hasRestoredScroll = false
                    }
                }
            }
        }
    }

    private func restoreScrollIfNeeded(proxy: ScrollViewProxy) {
        if scrollPosition == nil {
            hasRestoredScroll = true
            return
        }

        guard !hasRestoredScroll, let position = scrollPosition else { return }

        // Only restore once the carousel exists; otherwise we might mark restored too early.
        let hasTarget = viewModel.personalizedCarousels.contains(where: { $0.type.rawValue == position })
        guard hasTarget else { return }

        proxy.scrollTo(position, anchor: .top)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            hasRestoredScroll = true
        }
    }

    private func mediaType(for carouselType: CarouselType) -> MediaType {
        switch carouselType {
        case .topTVPicks:
            return .tv
        default:
            return .movie
        }
    }
}

struct DiscoveryHeaderView: View {
    let onSearchTap: () -> Void
    let onFilterTap: () -> Void
    let onProfileTap: () -> Void
    let avatarURL: String?
    let isProUser: Bool
    let activeFilterCount: Int
    
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image("logo_56x56")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                
                Text("discovery.vibeWatch".localized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .layoutPriority(1)
                    .minimumScaleFactor(0.8)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }

                Button(action: onFilterTap) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                        .overlay(alignment: .topTrailing) {
                            if activeFilterCount > 0 {
                                Text("\(activeFilterCount)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Color.theme.accentOrange)
                                    .clipShape(Circle())
                                    .offset(x: 4, y: -4)
                            }
                        }
                }

                ProUpgradeIconButton(isProUser: isProUser, source: "discovery_top_right")
                
                Button(action: onProfileTap) {
                    if let avatarURL = avatarURL, let url = URL(string: avatarURL) {
                        CachedAsyncImage(url: url) { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.theme.textSecondary)
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Color.theme.navigationBackground
                .ignoresSafeArea()
                .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        }
    }
}

struct MoodCarouselSection: View {
    let movies: [Movie]
    let descriptions: [String: String]
    @Binding var currentIndex: Int
    let onMovieTap: (Movie) -> Void
    @ObservedObject var localizationManager = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("discovery.basedOnMood".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            
            TabView(selection: $currentIndex) {
                ForEach(Array(movies.prefix(5).enumerated()), id: \.element.id) { index, movie in
                    MoodCarouselCard(
                        movie: movie,
                        description: descriptions[String(movie.id)]
                    ) {
                        onMovieTap(movie)
                    }
                    .tag(index)
                }
            }
            .frame(height: 500)
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            HStack(spacing: 6) {
                ForEach(0..<min(5, movies.count), id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? Color.theme.accentOrange : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
    }
}

struct MoodCarouselCard: View {
    let movie: Movie
    let description: String?
    let onTap: () -> Void

    private var displayDescription: String {
        if let description, !description.isEmpty {
            return description
        }
        return movie.overview
    }
    
    var body: some View {
        Button(action: onTap) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    CachedAsyncImage(url: movie.backdropURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: 500)
                        .clipped()
                        .overlay {
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.black.opacity(0.3),
                                    Color.black.opacity(0.7),
                                    Color.black.opacity(0.95)
                                ],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                        }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(movie.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.theme.accentOrange)
                                Text(movie.rating)
                                    .foregroundColor(.white)
                            }
                            
                            if let year = movie.year {
                                Text(year)
                                    .foregroundColor(.theme.textSecondary)
                            }
                        }
                        .font(.system(size: 13))
                        
                        Text(displayDescription)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .frame(height: 500)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 20)
    }
}

struct MediaSection: View {
    let title: String
    let items: [Movie]
    let descriptions: [String: String]
    let type: MediaType
    let scrollToMovieId: Int?
    let onMovieTap: (Movie) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
            
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { movie in
                            MediaCard(
                                movie: movie,
                                description: descriptions[String(movie.id)]
                            )
                                .id(movie.id)
                                .onTapGesture {
                                    onMovieTap(movie)
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .onAppear {
                    if let movieId = scrollToMovieId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo(movieId, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MediaCard: View {
    let movie: Movie
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: movie.posterURL)
                .aspectRatio(contentMode: .fill)
                .frame(width: 140, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(movie.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)
                .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.theme.accentOrange)
                Text(movie.rating)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }

            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(2)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }
}

#Preview {
    MainTabView()
}
