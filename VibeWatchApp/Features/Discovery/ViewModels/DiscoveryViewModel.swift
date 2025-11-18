import Foundation
import SwiftUI

@MainActor
class DiscoveryViewModel: ObservableObject {
    @Published var moodMovies: [Movie] = []
    @Published var forYouMovies: [Movie] = []
    @Published var viralMovies: [Movie] = []
    @Published var forYouTVShows: [Movie] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let tmdbService = TMDBService.shared
    private let cacheManager = ContentCacheManager.shared
    
    // Track the language/country used for current content
    private var cachedLanguage: String?
    private var cachedCountry: String?
    
    func loadContent(forceRefresh: Bool = false) async {
        let currentLanguage = LocalizationManager.shared.currentLanguage.id
        let currentCountry = LocalizationManager.shared.currentCountry.id
        
        // Check if language or country changed
        let languageChanged = cachedLanguage != currentLanguage || cachedCountry != currentCountry
        
        // Check if we have cached content from today and language hasn't changed
        if !forceRefresh && !languageChanged && !cacheManager.shouldUpdateDiscoveryContent() {
            if let cachedMovies = cacheManager.getCachedDiscoveryMovies(),
               let cachedTVShows = cacheManager.getCachedDiscoveryTVShows() {
                // Use cached content - same content for the whole day
                self.moodMovies = Array(cachedMovies.prefix(20))
                self.forYouMovies = Array(cachedMovies.dropFirst(20).prefix(20))
                self.viralMovies = Array(cachedMovies.dropFirst(40).prefix(20))
                self.forYouTVShows = cachedTVShows
                print("✅ Using cached discovery content from today")
                return
            }
        }
        
        // Need to fetch fresh content (either new day or language changed)
        if languageChanged {
            print("🌍 Language changed to \(currentLanguage)-\(currentCountry), fetching new content")
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // Fetch more movies for better randomization
            async let moodResponse = tmdbService.getTopRatedMovies(page: 1)
            async let forYouResponse = tmdbService.getPopularMovies(page: 1)
            async let viralResponse = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
            async let tvResponse = tmdbService.getPopularTVShows(page: 1)
            
            let (mood, forYou, viral, tv) = try await (moodResponse, forYouResponse, viralResponse, tvResponse)
            
            // Combine all movies for randomization
            var allMovies = mood.results + forYou.results + viral.results
            
            // Convert TV shows
            let tvShows = tv.results.map { tvShow in
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
                    productionCountries: tvShow.productionCountries
                )
            }
            
            // Cache for today with current language
            cacheManager.cacheDiscoveryContent(movies: allMovies, tvShows: tvShows)
            
            // Update tracked language/country
            cachedLanguage = currentLanguage
            cachedCountry = currentCountry
            
            // Shuffle and split
            allMovies.shuffle()
            self.moodMovies = Array(allMovies.prefix(20))
            self.forYouMovies = Array(allMovies.dropFirst(20).prefix(20))
            self.viralMovies = Array(allMovies.dropFirst(40).prefix(20))
            self.forYouTVShows = tvShows.shuffled()
            
            print("✅ Fetched and cached new discovery content for \(currentLanguage)-\(currentCountry)")
        } catch {
            errorMessage = error.localizedDescription
            print("Error loading content: \(error)")
        }
        
        isLoading = false
    }
}
