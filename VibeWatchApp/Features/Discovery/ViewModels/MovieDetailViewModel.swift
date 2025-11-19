import Foundation

@MainActor
class MovieDetailViewModel: ObservableObject {
    @Published var movie: Movie?
    @Published var credits: Credits?
    @Published var videos: [Video] = []
    @Published var watchProviders: CountryProviders?
    @Published var similarMovies: [Movie] = []
    @Published var imdbId: String?
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
        async let externalIdsTask = tmdbService.getMovieExternalIds(id: movieId)
        
        do {
            let (movieData, creditsData, videosData, providersData, similarData, externalIdsData) = try await (
                movieTask, creditsTask, videosTask, providersTask, similarTask, externalIdsTask
            )
            
            movie = movieData
            credits = creditsData
            videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
            imdbId = externalIdsData.imdbId
            
            // Use current country for watch providers
            let country = LocalizationManager.shared.currentCountry.id
            watchProviders = providersData.results?[country]
            
            similarMovies = Array(similarData.results.prefix(10))
            
            print("🎬 [MovieDetail] IMDB ID: \(imdbId ?? "nil")")
            print("🔗 [MovieDetail] JustWatch Link: \(watchProviders?.link ?? "nil")")
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
    @Published var imdbId: String?
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
        async let externalIdsTask = tmdbService.getTVShowExternalIds(id: tvShowId)
        
        do {
            let (tvShowData, creditsData, videosData, providersData, similarData, externalIdsData) = try await (
                tvShowTask, creditsTask, videosTask, providersTask, similarTask, externalIdsTask
            )
            
            tvShow = tvShowData
            credits = creditsData
            videos = videosData.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
            imdbId = externalIdsData.imdbId
            
            // Use current country for watch providers
            let country = LocalizationManager.shared.currentCountry.id
            watchProviders = providersData.results?[country]
            
            similarShows = Array(similarData.results.prefix(10))
            
            print("📺 [TVShowDetail] IMDB ID: \(imdbId ?? "nil")")
            print("🔗 [TVShowDetail] JustWatch Link: \(watchProviders?.link ?? "nil")")
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
