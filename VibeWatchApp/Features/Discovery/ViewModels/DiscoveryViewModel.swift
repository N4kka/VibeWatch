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
    
    func loadContent() async {
        isLoading = true
        errorMessage = nil
        
        do {
            async let moodResponse = tmdbService.getTopRatedMovies(page: 1)
            async let forYouResponse = tmdbService.getPopularMovies(page: 1)
            async let viralResponse = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
            async let tvResponse = tmdbService.getPopularTVShows(page: 1)
            
            let (mood, forYou, viral, tv) = try await (moodResponse, forYouResponse, viralResponse, tvResponse)
            
            self.moodMovies = mood.results
            self.forYouMovies = forYou.results
            self.viralMovies = viral.results
            self.forYouTVShows = tv.results.map { tvShow in
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
                    adult: false,
                    originalLanguage: tvShow.originalLanguage,
                    popularity: tvShow.popularity
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            print("Error loading content: \(error)")
        }
        
        isLoading = false
    }
}
