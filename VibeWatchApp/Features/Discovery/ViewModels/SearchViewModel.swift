import Foundation
import Combine

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
    @Published var trendingSearches: [SearchResult] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var searchTask: Task<Void, Never>?
    private let tmdbService = TMDBService.shared
    
    init() {
        loadTrendingSearches()
    }
    
    func search() {
        searchTask?.cancel()
        
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        
        searchTask = Task {
            isLoading = true
            errorMessage = nil
            
            do {
                let response = try await tmdbService.searchMulti(query: searchQuery)
                if !Task.isCancelled {
                    searchResults = response.results.filter { result in
                        result.mediaType == "movie" || result.mediaType == "tv"
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = "Failed to search: \(error.localizedDescription)"
                }
            }
            
            isLoading = false
        }
    }
    
    func loadTrendingSearches() {
        Task {
            do {
                let moviesResponse = try await tmdbService.getTrendingMovies()
                let tvResponse = try await tmdbService.getTrendingTVShows()
                
                let movieResults = moviesResponse.results.prefix(5).map { movie in
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
                
                let tvResults = tvResponse.results.prefix(5).map { show in
                    SearchResult(
                        id: show.id,
                        mediaType: "tv",
                        title: nil,
                        name: show.name,
                        overview: show.overview,
                        posterPath: show.posterPath,
                        backdropPath: show.backdropPath,
                        releaseDate: nil,
                        firstAirDate: show.firstAirDate,
                        voteAverage: show.voteAverage,
                        voteCount: show.voteCount
                    )
                }
                
                trendingSearches = Array(movieResults + tvResults)
            } catch {
                errorMessage = "Failed to load trending: \(error.localizedDescription)"
            }
        }
    }
}
