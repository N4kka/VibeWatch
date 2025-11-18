import Foundation

@MainActor
class MovieDetailViewModel: ObservableObject {
    @Published var movie: Movie?
    @Published var credits: Credits?
    @Published var videos: [Video] = []
    @Published var watchProviders: CountryProviders?
    @Published var similarMovies: [Movie] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let tmdbService = TMDBService.shared
    private let movieId: Int
    
    init(movieId: Int) {
        self.movieId = movieId
    }
    
    func loadMovieDetails() async {
        isLoading = true
        errorMessage = nil
        
        async let movieTask = tmdbService.getMovieDetails(id: movieId)
        async let creditsTask = tmdbService.getMovieCredits(id: movieId)
        async let videosTask = tmdbService.getMovieVideos(id: movieId)
        async let providersTask = tmdbService.getMovieWatchProviders(id: movieId)
        async let similarTask = tmdbService.getSimilarMovies(id: movieId)
        
        do {
            let (movieData, creditsData, videosData, providersData, similarData) = try await (
                movieTask, creditsTask, videosTask, providersTask, similarTask
            )
            
            movie = movieData
            credits = creditsData
            videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
            watchProviders = providersData.results?["US"]
            similarMovies = Array(similarData.results.prefix(10))
        } catch {
            errorMessage = "Failed to load movie details: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    var director: Crew? {
        credits?.crew.first { $0.job == "Director" }
    }
    
    var mainCast: [Cast] {
        Array(credits?.cast.prefix(10) ?? [])
    }
    
    var trailer: Video? {
        videos.first
    }
}

@MainActor
class TVShowDetailViewModel: ObservableObject {
    @Published var tvShow: TVShow?
    @Published var credits: Credits?
    @Published var videos: [Video] = []
    @Published var watchProviders: CountryProviders?
    @Published var similarShows: [TVShow] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let tmdbService = TMDBService.shared
    private let tvShowId: Int
    
    init(tvShowId: Int) {
        self.tvShowId = tvShowId
    }
    
    func loadTVShowDetails() async {
        isLoading = true
        errorMessage = nil
        
        async let tvShowTask = tmdbService.getTVShowDetails(id: tvShowId)
        async let creditsTask = tmdbService.getTVShowCredits(id: tvShowId)
        async let videosTask = tmdbService.getTVShowVideos(id: tvShowId)
        async let providersTask = tmdbService.getTVShowWatchProviders(id: tvShowId)
        async let similarTask = tmdbService.getSimilarTVShows(id: tvShowId)
        
        do {
            let (tvShowData, creditsData, videosData, providersData, similarData) = try await (
                tvShowTask, creditsTask, videosTask, providersTask, similarTask
            )
            
            tvShow = tvShowData
            credits = creditsData
            videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
            watchProviders = providersData.results?["US"]
            similarShows = Array(similarData.results.prefix(10))
        } catch {
            errorMessage = "Failed to load TV show details: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    var mainCast: [Cast] {
        Array(credits?.cast.prefix(10) ?? [])
    }
    
    var trailer: Video? {
        videos.first
    }
}
