import SwiftUI

struct DiscoveryView: View {
    @StateObject private var viewModel = DiscoveryViewModel()
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var gamificationService = GamificationService.shared
    /// Redesign 2.0: strip "In uscita" e "Continua a guardare" leggono lo specchio del Tracking.
    @StateObject private var trackingHighlights = DiscoveryTrackingHighlightsViewModel()
    /// Redesign 2.0 import: il banner di stato (in corso / da verificare / completato) e la
    /// pagina "Titoli da verificare" vivono qui, sotto l'header di Scopri.
    @ObservedObject private var importCenter = ImportStatusCenter.shared
    @State private var showReleaseCalendar = false
    @State private var releaseCalendarDay: Date? = nil
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @ObservedObject var localizationManager = LocalizationManager.shared
    @State private var showProfile = false
    @State private var showSearch = false
    @State private var showFilters = false
    @Binding var selectedMovie: Movie?
    @Binding var selectedMediaType: MediaType
    /// Redesign 2.0: Scopri e Clip sono due modalità dello stesso tab. Il binding arriva da
    /// `DiscoverHubView`; qui serve solo per disegnare lo switcher sotto l'header.
    @Binding var discoverMode: DiscoverMode
    @State private var scrollPosition: String? = nil
    @State private var moodCarouselIndex = 0
    @State private var lastTappedMovieId: Int? = nil
    @State private var hasRestoredScroll = false
    @State private var filterSessionId = UUID().uuidString

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.hasNoContent {
                DiscoverySkeletonView()
            } else if let error = viewModel.error, viewModel.hasNoContent {
                errorView(error)
            } else {
                discoveryMainView
            }
        }
        .background(Color.theme.background.ignoresSafeArea())
        .task {
            // Lo stream dei caroselli può durare decine di secondi (rigenerazione TMDB):
            // parte subito ma NON blocca il resto del task — prima la strip del tracking e
            // la gamification aspettavano la fine dell'intero stream.
            async let content: Void = viewModel.loadContentIfNeeded()
            await trackingHighlights.load()

            // Load gamification state
            if let userId = appState.currentUser?.id {
                await gamificationService.loadUserState(userId: userId)

                // Award (and show the toast for) the daily-login bonus at most once per
                // local calendar day. The local gate is authoritative so the popup never
                // re-appears on repeat launches the same day, even if the remote state is
                // stale or unavailable. We only persist the "shown today" marker once the
                // award actually succeeds, so a failed/offline attempt can retry next launch.
                let isPro = quotaManager.isProUser
                if gamificationService.shouldAwardDailyOpen(userId: userId) {
                    let event = await gamificationService.awardXP(userId: userId, action: .dailyOpen, isPro: isPro)
                    if event != nil {
                        gamificationService.markDailyOpenAwarded(userId: userId)
                    }
                }
            }

            // Analytics: Track screen view
            AnalyticsService.shared.logScreenView(screenName: "Discovery", screenClass: "DiscoveryView")

            // Debug: Print reaction counts
            await SQLiteService.shared.debugPrintReactionCounts()

            _ = await content
        }
        .onChange(of: localizationManager.localeDidChange) {_, _ in
            // Clears personalized_discovery cache and re-fetches from TMDB in the new locale
            // so both carousel titles (via CarouselTitleSpec) and movie/TV titles update.
            Task { await viewModel.refreshContent() }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showReleaseCalendar) {
            ReleaseCalendarView(viewModel: trackingHighlights, initialDay: releaseCalendarDay)
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView(viewModel: searchViewModel)
        }
        .fullScreenCover(isPresented: $showFilters) {
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
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $importCenter.showReviewSheet) {
            ImportReviewView()
        }
        .toast(isShowing: $appState.showSuccessToast, message: appState.toastMessage, type: .success)
        .toast(isShowing: $appState.showErrorToast, message: appState.toastMessage, type: .error)
        // Redesign 2.0 import: "Libreria importata · N titoli da verificare", una volta per job.
        .toast(isShowing: Binding(
            get: { importCenter.toastMessage != nil },
            set: { if !$0 { importCenter.toastMessage = nil } }
        ), message: importCenter.toastMessage ?? "", type: .success)
        .xpToast(gamificationService: gamificationService)
        .onChange(of: appState.shouldShowSignIn) {_, newValue in
            if newValue {
                Logger.info("[DiscoveryView] Redirecting to Sign In via Profile")
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

            // Redesign 2.0: l'header globale è FISSO, fuori dallo scroll — nel prototipo è
            // sempre visibile su ogni tab, e il contenuto scorre sotto di lui.
            AppHeaderView(
                onSearchTap: { showSearch = true },
                onProfileTap: { showProfile = true },
                avatarURL: appState.currentUser?.avatarURL
            )

            // Redesign 2.0 import: lo stato dell'import sotto l'header — in corso con la
            // percentuale reale, completato con "Gestisci" se restano titoli da verificare,
            // verde con "OK" se è tutto in ordine.
            ImportStatusBanner(center: importCenter)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 32) {
                        ZStack {
                            DiscoverModeSwitcher(mode: $discoverMode)

                            HStack {
                                Spacer()
                                DiscoveryFilterButton(
                                    activeFilterCount: viewModel.globalFilters.activeFilterCount
                                ) {
                                    filterSessionId = UUID().uuidString
                                    showFilters = true
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                        // Le due sezioni "di casa" (prototipo 2.0): cosa esce e cosa stavi
                        // guardando, PRIMA delle raccomandazioni. Compaiono solo se lo specchio
                        // locale del tracking ha materiale: per un anonimo non esistono.
                        if !trackingHighlights.upcoming.isEmpty {
                            ReleaseStripSection(viewModel: trackingHighlights) { day in
                                releaseCalendarDay = day
                                showReleaseCalendar = true
                            }
                        }

                        if !trackingHighlights.continueWatching.isEmpty {
                            ContinueWatchingSection(viewModel: trackingHighlights) { showId in
                                openShow(showId)
                            }
                        }

                        ForEach(viewModel.visibleCarousels, id: \.type.rawValue) { carousel in
                            if carousel.type == .dailyMix {
                                MoodCarouselSection(
                                    movies: carousel.items,
                                    descriptions: carousel.descriptions,
                                    currentIndex: $moodCarouselIndex
                                ) { movie in
                                    scrollPosition = carousel.type.rawValue
                                    viewModel.recordCarouselClick(movie: movie, carouselType: carousel.type, mediaType: .movie)
                                    var target = movie
                                    target.navigationMediaType = .movie
                                    selectedMediaType = .movie
                                    selectedMovie = target
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
                                    var target = movie
                                    target.navigationMediaType = mediaType
                                    selectedMediaType = mediaType
                                    selectedMovie = target
                                }
                                .id(carousel.type.rawValue)
                            }
                        }
                    
                        if viewModel.hasMoreCarousels {
                            HStack { ProgressView() }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .onAppear { viewModel.loadMoreCarousels() }
                        } else if viewModel.personalizedCarousels.count > 11 {
                            Text("discovery.endOfFeed".localized)
                                .font(.system(size: 13))
                                .foregroundColor(.theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }

                        Color.clear
                            .frame(height: 80)
                    }
                }
                .id(viewModel.refreshToken)
                .refreshable {
                    // Force refresh from TMDB to get latest content and reload images
                    Logger.debug("[DiscoveryView] Pull-to-refresh triggered")
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

    /// Apre il dettaglio di una serie dalle sezioni tracking. Il placeholder con il solo id è lo
    /// stesso contratto dei deep link: `navigationDestination` usa solo `movie.id`.
    private func openShow(_ showId: Int) {
        var placeholder = Movie(
            id: showId, title: "", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: nil, voteAverage: 0, voteCount: 0, genreIds: nil, genres: nil,
            adult: false, originalLanguage: "", popularity: 0, runtime: nil, status: nil,
            tagline: nil, productionCountries: nil, imdbId: nil
        )
        // Il tipo sta nell'item (vedi Movie.navigationMediaType): con il solo stato parallelo
        // la destination poteva leggere `.movie` stantio e aprire il film omonimo per id.
        placeholder.navigationMediaType = .tv
        selectedMediaType = .tv
        selectedMovie = placeholder
    }

    private func mediaType(for carouselType: CarouselType) -> MediaType {
        switch carouselType {
        case .topTVPicks, .trendingTVWeek, .returningTV:
            return .tv
        default:
            return .movie
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
            CachedAsyncImage(url: movie.posterURL, maxPixelSize: 630)
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
