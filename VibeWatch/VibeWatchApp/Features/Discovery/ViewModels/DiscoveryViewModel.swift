import Foundation
import SwiftUI
import Combine

@MainActor
class DiscoveryViewModel: ObservableObject {
    @Published var moodMovies: [Movie] = []
    @Published var forYouMovies: [Movie] = []
    @Published var viralMovies: [Movie] = []
    @Published var forYouTVShows: [Movie] = []
    @Published var browseMovies: [Movie] = []
    @Published var browseTVShows: [Movie] = []
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var isBrowseLoading = false
    @Published var error: AppError?
    @Published var filters = DiscoveryFilters()
    @Published var selectedBrowseType: MediaType = .movie
    @Published var refreshToken = UUID()
    
    var hasNoContent: Bool {
        moodMovies.isEmpty && forYouMovies.isEmpty && viralMovies.isEmpty && forYouTVShows.isEmpty
    }
    
    private let dataCoordinator = DataCoordinator.shared
    private let tmdbService: TMDBServiceProtocol
    private let discoveryCache = DiscoveryCacheService.shared
    private let quotaManager: DailyQuotaManager
    private var cancellables = Set<AnyCancellable>()
    private var browseTask: Task<Void, Never>?
    
    init(
        tmdbService: TMDBServiceProtocol = TMDBService.shared,
        quotaManager: DailyQuotaManager = .shared
    ) {
        self.tmdbService = tmdbService
        self.quotaManager = quotaManager
        subscribeToListChanges()
    }
    
    private func subscribeToListChanges() {
        ListManager.shared.$seenList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refilterBrowseResults()
            }
            .store(in: &cancellables)

        ListManager.shared.$dislikedList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refilterBrowseResults()
            }
            .store(in: &cancellables)
    }
    
    private func refilterBrowseResults() {
        guard quotaManager.isProUser else { return }

        self.browseMovies = filterSeenAndDisliked(movies: self.browseMovies)
        self.browseTVShows = filterSeenAndDisliked(movies: self.browseTVShows)
    }
    
    // Alias for loadContent to fix call site compatibility
    func loadDiscoveryContent() async {
        await loadContent()
    }

    /// Load content - uses database cache for instant loading!
    func loadContent(forceRefresh: Bool = false) async {
        print("📺 [DiscoveryViewModel] Loading content... forceRefresh: \(forceRefresh)")
        
        if forceRefresh {
            isRefreshing = true
        } else {
            isLoading = true
        }
        error = nil
        
        do {
            // If forceRefresh is true (e.g., language changed), fetch fresh and update cache
            if forceRefresh {
                print("🔄 [DiscoveryViewModel] Force refresh requested...")
                try await discoveryCache.refreshContent()
            }
            
            // Get content from cache (DB or in-memory) - INSTANT!
            let content = try await discoveryCache.getDiscoveryContent()
            
            // Assign to published properties
            self.viralMovies = Array(content.trending.prefix(20))
            self.moodMovies = Array(content.topRated.prefix(20))
            self.forYouMovies = Array(content.popular.prefix(20))
            
            // Convert TV shows to Movie format for display
            self.forYouTVShows = content.tv.prefix(20).map { tvShow in
                Movie(
                    id: tvShow.id,
                    title: tvShow.name,
                    overview: tvShow.overview,
                    posterPath: tvShow.posterPath,
                    backdropPath: tvShow.backdropPath,
                    releaseDate: tvShow.firstAirDate,
                    voteAverage: tvShow.voteAverage,
                    voteCount: tvShow.voteCount,
                    genreIds: tvShow.genreIds,
                    genres: tvShow.genres,
                    adult: false,
                    originalLanguage: tvShow.originalLanguage,
                    popularity: tvShow.popularity,
                    runtime: nil,
                    status: tvShow.status,
                    tagline: tvShow.tagline,
                    productionCountries: tvShow.productionCountries,
                    imdbId: tvShow.imdbId
                )
            }
            
            if quotaManager.isProUser {
                self.viralMovies = filterSeenAndDisliked(movies: self.viralMovies)
                self.moodMovies = filterSeenAndDisliked(movies: self.moodMovies)
                self.forYouMovies = filterSeenAndDisliked(movies: self.forYouMovies)
                self.forYouTVShows = filterSeenAndDisliked(movies: self.forYouTVShows)
            }
            
            print("✅ [DiscoveryViewModel] Loaded from cache (instant!)")
            
        } catch {
            print("❌ [DiscoveryViewModel] Failed to load from cache: \(error)")
            self.error = AppError.database(error)
        }
        
        isLoading = false
        isRefreshing = false
        refreshToken = UUID()
    }
    
    private func filterSeenAndDisliked(movies: [Movie]) -> [Movie] {
        let listManager = ListManager.shared
        let seenItems = Set(listManager.seenList.items.map { $0.mediaId })
        let dislikedItems = Set(listManager.dislikedList.items.map { $0.mediaId })
        let excludedItems = seenItems.union(dislikedItems)

        return movies.filter { !excludedItems.contains($0.id) }
    }
    
    /// Refresh content - called by pull-to-refresh gesture
    func refreshContent() async {
        print("🔄 [DiscoveryViewModel] Pull-to-refresh: Fetching fresh content from TMDB...")
        
        do {
            // Force refresh from TMDB
            try await discoveryCache.refreshContent()
            
            // Get updated content
            let content = try await discoveryCache.getDiscoveryContent()
            
            // Update UI
            self.viralMovies = Array(content.trending.prefix(20))
            self.moodMovies = Array(content.topRated.prefix(20))
            self.forYouMovies = Array(content.popular.prefix(20))
            
            self.forYouTVShows = content.tv.prefix(20).map { tvShow in
                Movie(
                    id: tvShow.id,
                    title: tvShow.name,
                    overview: tvShow.overview,
                    posterPath: tvShow.posterPath,
                    backdropPath: tvShow.backdropPath,
                    releaseDate: tvShow.firstAirDate,
                    voteAverage: tvShow.voteAverage,
                    voteCount: tvShow.voteCount,
                    genreIds: tvShow.genreIds,
                    genres: tvShow.genres,
                    adult: false,
                    originalLanguage: tvShow.originalLanguage,
                    popularity: tvShow.popularity,
                    runtime: nil,
                    status: tvShow.status,
                    tagline: tvShow.tagline,
                    productionCountries: tvShow.productionCountries,
                    imdbId: tvShow.imdbId
                )
            }

            if quotaManager.isProUser {
                self.viralMovies = filterSeenAndDisliked(movies: self.viralMovies)
                self.moodMovies = filterSeenAndDisliked(movies: self.moodMovies)
                self.forYouMovies = filterSeenAndDisliked(movies: self.forYouMovies)
                self.forYouTVShows = filterSeenAndDisliked(movies: self.forYouTVShows)
            }
            
            print("✅ [DiscoveryViewModel] Refresh complete!")
            
        } catch {
            print("❌ [DiscoveryViewModel] Refresh failed: \(error)")
            self.error = AppError.network(error)
        }
        refreshToken = UUID()
    }
    
    /// Browse with filters - uses TMDb discover endpoint
    func browseWithFilters() async {
        // Cancel any existing browse task
        browseTask?.cancel()
        
        print("🔍 [DiscoveryViewModel] Browsing with filters: \(filters)")
        
        isBrowseLoading = true
        
        // Create new task and store it
        browseTask = Task {
            do {
                try Task.checkCancellation()
                try await performBrowse()
            } catch is CancellationError {
                print("⚠️ [DiscoveryViewModel] Browse task was cancelled")
            } catch {
                await MainActor.run {
                    self.error = AppError.network(error)
                    print("❌ [DiscoveryViewModel] Failed to browse: \(error)")
                }
            }
            
            await MainActor.run {
                self.isBrowseLoading = false
            }
        }
        
        await browseTask?.value
    }
    
    private func performBrowse() async throws {
        do {
            if selectedBrowseType == .movie {
                let response = try await tmdbService.discoverMovies(
                    withGenre: nil,
                    sortBy: filters.sortBy.tmdbValue,
                    page: 1,
                    minRuntime: filters.runtimeRange.minRuntime,
                    maxRuntime: filters.runtimeRange.maxRuntime,
                    minRating: filters.ratingRange.minRating,
                    country: filters.country
                )
                if quotaManager.isProUser {
                    browseMovies = filterSeenAndDisliked(movies: response.results)
                } else {
                    browseMovies = response.results
                }
                print("✅ [DiscoveryViewModel] Found \(browseMovies.count) movies")
            } else {
                let response = try await tmdbService.discoverTVShows(
                    withGenre: nil,
                    sortBy: filters.sortBy.tmdbValue,
                    page: 1,
                    minRating: filters.ratingRange.minRating,
                    country: filters.country
                )
                // Convert TV shows to Movie format for display
                let showsAsMovies = response.results.map { tvShow in
                    Movie(
                        id: tvShow.id,
                        title: tvShow.name,
                        overview: tvShow.overview,
                        posterPath: tvShow.posterPath,
                        backdropPath: tvShow.backdropPath,
                        releaseDate: tvShow.firstAirDate,
                        voteAverage: tvShow.voteAverage,
                        voteCount: tvShow.voteCount,
                        genreIds: tvShow.genreIds,
                        genres: tvShow.genres,
                        adult: false,
                        originalLanguage: tvShow.originalLanguage,
                        popularity: tvShow.popularity,
                        runtime: nil,
                        status: tvShow.status,
                        tagline: tvShow.tagline,
                        productionCountries: tvShow.productionCountries,
                        imdbId: tvShow.imdbId
                    )
                }
                if quotaManager.isProUser {
                    browseTVShows = filterSeenAndDisliked(movies: showsAsMovies)
                } else {
                    browseTVShows = showsAsMovies
                }
                print("✅ [DiscoveryViewModel] Found \(browseTVShows.count) TV shows")
            }
        } catch {
            throw error
        }
    }
    
    /// Fallback method to fetch fresh content if needed
    private func fetchFreshContent() async {
        do {
            async let trending = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
            async let topRated = tmdbService.getTopRatedMovies(page: 1)
            async let popular = tmdbService.getPopularMovies(page: 1)
            async let tv = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
            
            let (trendingRes, topRatedRes, popularRes, tvRes) = try await (trending, topRated, popular, tv)
            
            self.viralMovies = Array(trendingRes.results.prefix(20))
            self.moodMovies = Array(topRatedRes.results.prefix(20))
            self.forYouMovies = Array(popularRes.results.prefix(20))
            
            self.forYouTVShows = tvRes.results.prefix(20).map { tvShow in
                Movie(
                    id: tvShow.id,
                    title: tvShow.name,
                    overview: tvShow.overview,
                    posterPath: tvShow.posterPath,
                    backdropPath: tvShow.backdropPath,
                    releaseDate: tvShow.firstAirDate,
                    voteAverage: tvShow.voteAverage,
                    voteCount: tvShow.voteCount,
                    genreIds: tvShow.genreIds,
                    genres: tvShow.genres,
                    adult: false,
                    originalLanguage: tvShow.originalLanguage,
                    popularity: tvShow.popularity,
                    runtime: nil,
                    status: tvShow.status,
                    tagline: tvShow.tagline,
                    productionCountries: tvShow.productionCountries,
                    imdbId: tvShow.imdbId
                )
            }
            
            print("✅ [DiscoveryViewModel] Fetched fresh content")
        } catch {
            self.error = AppError.network(error)
            print("❌ [DiscoveryViewModel] Failed to fetch fresh content: \(error)")
        }
    }
}
