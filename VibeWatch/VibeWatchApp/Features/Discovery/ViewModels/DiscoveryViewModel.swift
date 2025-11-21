import Foundation
import SwiftUI

@MainActor
class DiscoveryViewModel: ObservableObject {
    @Published var moodMovies: [Movie] = []
    @Published var forYouMovies: [Movie] = []
    @Published var viralMovies: [Movie] = []
    @Published var forYouTVShows: [Movie] = []
    @Published var browseMovies: [Movie] = []
    @Published var browseTVShows: [Movie] = []
    @Published var isLoading = false
    @Published var isBrowseLoading = false
    @Published var errorMessage: String?
    @Published var filters = DiscoveryFilters()
    @Published var selectedBrowseType: MediaType = .movie
    
    private let dataCoordinator = DataCoordinator.shared
    private let tmdbService = TMDBService.shared
    
    /// Load content - uses shared data from DataCoordinator (no API calls needed!)
    func loadContent(forceRefresh: Bool = false) async {
        print("📺 [DiscoveryViewModel] Loading content... forceRefresh: \(forceRefresh)")
        
        isLoading = true
        errorMessage = nil
        
        // If forceRefresh is true (e.g., language changed), fetch fresh content
        if forceRefresh {
            print("🔄 [DiscoveryViewModel] Force refresh requested, fetching fresh content...")
            await fetchFreshContent()
            // Also refresh the DataCoordinator cache so other views get updated data
            await dataCoordinator.refreshDiscoveryContent()
            isLoading = false
            return
        }
        
        // Get shared data from DataCoordinator (already fetched on app launch)
        if let sharedContent = await dataCoordinator.getDiscoveryContent() {
            // Use preloaded data - INSTANT, no API calls!
            self.viralMovies = Array(sharedContent.movies.prefix(20))
            self.moodMovies = Array(sharedContent.topRated.prefix(20))
            self.forYouMovies = Array(sharedContent.popular.prefix(20))
            
            // Convert TV shows to Movie format for display
            self.forYouTVShows = sharedContent.tvShows.prefix(20).map { tvShow in
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
            
            print("✅ [DiscoveryViewModel] Loaded from shared cache (0 API calls)")
        } else {
            // Fallback: fetch fresh if coordinator hasn't loaded yet
            print("⚠️ [DiscoveryViewModel] Shared cache not ready, fetching fresh...")
            await fetchFreshContent()
        }
        
        isLoading = false
    }
    
    /// Browse with filters - uses TMDb discover endpoint
    func browseWithFilters() async {
        print("🔍 [DiscoveryViewModel] Browsing with filters: \(filters)")
        
        isBrowseLoading = true
        
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
                browseMovies = response.results
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
                browseTVShows = response.results.map { tvShow in
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
                print("✅ [DiscoveryViewModel] Found \(browseTVShows.count) TV shows")
            }
        } catch {
            errorMessage = error.localizedDescription
            print("❌ [DiscoveryViewModel] Failed to browse: \(error)")
        }
        
        isBrowseLoading = false
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
            errorMessage = error.localizedDescription
            print("❌ [DiscoveryViewModel] Failed to fetch fresh content: \(error)")
        }
    }
}
