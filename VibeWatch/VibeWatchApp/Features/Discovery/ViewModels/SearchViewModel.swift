import Foundation
import Combine

struct VisitedItem: Codable, Equatable {
    let id: Int
    let mediaType: String // "movie" or "tv"
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
    @Published var trendingSearches: [SearchResult] = []
    @Published var latestVisitedItems: [SearchResult] = []
    @Published var isLoading = false
    @Published var error: AppError?
    
    private var searchTask: Task<Void, Never>?
    private let tmdbService = TMDBService.shared
    private let preferenceManager = UserPreferenceManager.shared
    private let visitedItemsKey = "latestVisitedItems" // UserDefaults key
    private let maxVisitedItems = 2 // Max items to store
    private var lastLoggedQuery: String?
    private var lastLoggedAt: Date?
    
    init() {
        Logger.debug("[SearchViewModel] init() called")
        self.loadTrendingSearches()
        Task { await self.loadLatestVisitedItems() }
    }    
    func search() {
        searchTask?.cancel()
        
        let currentQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentQuery.isEmpty else {
            searchResults = []
            return
        }
        
        searchTask = Task {
            // Debounce input so we don't spam both TMDB and search-history logging.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            isLoading = true
            error = nil
            
            do {
                let response = try await tmdbService.searchMulti(query: currentQuery, page: 1)
                if !Task.isCancelled {
                    searchResults = response.results.filter { result in
                        result.mediaType == "movie" || result.mediaType == "tv"
                    }
                    await logSearchIfNeeded(query: currentQuery, resultCount: searchResults.count)
                }
            } catch {
                if !Task.isCancelled {
                    self.error = AppError.network(error)
                }
            }
            
            isLoading = false
        }
    }

    func handleResultTap(_ result: SearchResult) {
        saveVisitedItem(id: result.id, mediaType: result.mediaType)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        Task {
            await preferenceManager.recordSearchClick(
                query: query,
                clickedMediaId: result.id,
                clickedMediaTitle: result.displayTitle,
                clickedMediaType: result.mediaType,
                resultCount: searchResults.count
            )
        }
    }

    private func logSearchIfNeeded(query: String, resultCount: Int) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else { return }

        if let last = lastLoggedQuery, last == normalized,
           let lastAt = lastLoggedAt,
           Date().timeIntervalSince(lastAt) < 10 {
            return
        }

        lastLoggedQuery = normalized
        lastLoggedAt = Date()

        await preferenceManager.recordSearchQuery(
            query: normalized,
            mediaType: nil,
            resultCount: resultCount
        )
    }
    
    func saveVisitedItem(id: Int, mediaType: String) {
        var items = getVisitedItems()
        let newItem = VisitedItem(id: id, mediaType: mediaType)
        
        // Remove if already exists to move to top
        items.removeAll { $0 == newItem }
        
        // Add to front
        items.insert(newItem, at: 0)
        
        // Keep only the latest 2
        if items.count > maxVisitedItems {
            items = Array(items.prefix(maxVisitedItems))
        }
        
        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: visitedItemsKey)
        }
        
        // Reload published property
        Task { await loadLatestVisitedItems() } // Reload after saving
    }

    private func getVisitedItems() -> [VisitedItem] {
        if let savedItemsData = UserDefaults.standard.data(forKey: visitedItemsKey),
           let decodedItems = try? JSONDecoder().decode([VisitedItem].self, from: savedItemsData) {
            return decodedItems
        }
        return []
    }
    
    func loadLatestVisitedItems() async {
        let storedItems = getVisitedItems()
        var loadedResults: [SearchResult] = []
        
        await withTaskGroup(of: SearchResult?.self) { group in
            for item in storedItems {
                group.addTask {
                    do {
                        if item.mediaType == "movie" {
                            let movie = try await self.tmdbService.getMovieDetails(id: item.id)
                            return SearchResult(
                                id: movie.id,
                                mediaType: "movie",
                                title: movie.title,
                                name: nil,
                                overview: movie.overview,
                                posterPath: movie.posterPath,
                                backdropPath: movie.backdropPath,
                                releaseDate: movie.releaseDate,
                                firstAirDate: nil,
                                voteAverage: movie.voteAverage,
                                voteCount: movie.voteCount
                            )
                        } else if item.mediaType == "tv" {
                            let tvShow = try await self.tmdbService.getTVShowDetails(id: item.id)
                            return SearchResult(
                                id: tvShow.id,
                                mediaType: "tv",
                                title: nil,
                                name: tvShow.name,
                                overview: tvShow.overview,
                                posterPath: tvShow.posterPath,
                                backdropPath: tvShow.backdropPath,
                                releaseDate: nil,
                                firstAirDate: tvShow.firstAirDate,
                                voteAverage: tvShow.voteAverage,
                                voteCount: tvShow.voteCount
                            )
                        }
                    } catch {
                        Logger.warning("[SearchViewModel] Error loading visited item \(item.id) (\(item.mediaType)): \(error)")
                    }
                    return nil
                }
            }
            
            for await result in group {
                if let result = result {
                    loadedResults.append(result)
                }
            }
        }
        
        // Ensure the order is preserved (most recent first)
        latestVisitedItems = storedItems.compactMap { storedItem in
            loadedResults.first { $0.id == storedItem.id && $0.mediaType == storedItem.mediaType }
        }
    }
    
    // MARK: - Trending
    
    func loadTrendingSearches() {
        Task {
            do {
                async let trendingMovies = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
                async let trendingTV = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
                
                let (moviesRes, tvRes) = try await (trendingMovies, trendingTV)
                
                // Map movies to SearchResult
                let movieResults: [SearchResult] = moviesRes.results.map { movie in
                    SearchResult(
                        id: movie.id,
                        mediaType: "movie",
                        title: movie.title,
                        name: nil,
                        overview: movie.overview,
                        posterPath: movie.posterPath,
                        backdropPath: movie.backdropPath,
                        releaseDate: movie.releaseDate,
                        firstAirDate: nil,
                        voteAverage: movie.voteAverage,
                        voteCount: movie.voteCount
                    )
                }
                
                // Map TV shows to SearchResult
                let tvResults: [SearchResult] = tvRes.results.map { tv in
                    SearchResult(
                        id: tv.id,
                        mediaType: "tv",
                        title: nil,
                        name: tv.name,
                        overview: tv.overview,
                        posterPath: tv.posterPath,
                        backdropPath: tv.backdropPath,
                        releaseDate: nil,
                        firstAirDate: tv.firstAirDate,
                        voteAverage: tv.voteAverage,
                        voteCount: tv.voteCount
                    )
                }
                
                // Combine and limit if desired
                let combined = Array((movieResults + tvResults).prefix(20))
                trendingSearches = combined
            } catch {
                self.error = AppError.network(error)
            }
        }
    }
}
