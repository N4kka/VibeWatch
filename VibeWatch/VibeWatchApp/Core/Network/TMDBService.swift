import Foundation

protocol TMDBServiceProtocol {
    func getTrendingMovies(timeWindow: TimeWindow, page: Int) async throws -> TMDBResponse<Movie>
    func getPopularMovies(page: Int) async throws -> TMDBResponse<Movie>
    func getTopRatedMovies(page: Int) async throws -> TMDBResponse<Movie>
    func discoverMovies(
        withGenre genreId: Int?,
        sortBy: String,
        page: Int,
        minRuntime: Int?,
        maxRuntime: Int?,
        minRating: Double?,
        country: String?
    ) async throws -> TMDBResponse<Movie>
    func searchMovies(query: String, page: Int) async throws -> TMDBResponse<Movie>
    func getTrendingTVShows(timeWindow: TimeWindow, page: Int) async throws -> TMDBResponse<TVShow>
    func getPopularTVShows(page: Int) async throws -> TMDBResponse<TVShow>
    func getTopRatedTVShows(page: Int) async throws -> TMDBResponse<TVShow>
    func discoverTVShows(
        withGenre genreId: Int?,
        sortBy: String,
        page: Int,
        minRating: Double?,
        country: String?
    ) async throws -> TMDBResponse<TVShow>
    func searchTVShows(query: String, page: Int) async throws -> TMDBResponse<TVShow>
    func searchMulti(query: String, page: Int) async throws -> TMDBMultiResponse
    func getMovieDetails(id: Int) async throws -> Movie
    func getMovieCredits(id: Int) async throws -> Credits
    func getMovieVideos(id: Int) async throws -> TMDBVideosResponse
    func getMovieWatchProviders(id: Int) async throws -> WatchProvider
    func getSimilarMovies(id: Int, page: Int) async throws -> TMDBResponse<Movie>
    func getTVShowDetails(id: Int) async throws -> TVShow
    func getTVShowCredits(id: Int) async throws -> Credits
    func getTVShowVideos(id: Int) async throws -> TMDBVideosResponse
    func getTVShowWatchProviders(id: Int) async throws -> WatchProvider
    func getSimilarTVShows(id: Int, page: Int) async throws -> TMDBResponse<TVShow>
    func getMovieExternalIds(id: Int) async throws -> ExternalIds
    func getTVShowExternalIds(id: Int) async throws -> ExternalIds
    func getPersonDetails(id: Int) async throws -> PersonDetails
    func getPersonCombinedCredits(id: Int) async throws -> PersonCombinedCredits
}

class TMDBService: TMDBServiceProtocol {
    @MainActor static let shared: TMDBServiceProtocol = TMDBService()
    
    private let baseURL = "https://api.themoviedb.org/3"
    private let apiKey = "e42f888f287ca2fbe26c9a6e70351fb7"
    private let session: URLSession
    private let cache: URLCache
    
    // Rate limiting actor to serialize requests
    private actor RequestSerializer {
        private var lastRequestTime: Date = .distantPast
        private let interval: TimeInterval = 0.25 // 4 requests per second
        
        func proceed() async {
            let now = Date()
            // Reserve the next available slot
            let targetTime = max(now, lastRequestTime.addingTimeInterval(interval))
            lastRequestTime = targetTime
            
            let delay = targetTime.timeIntervalSince(now)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    
    private let serializer = RequestSerializer()
    
    private init() {
        let config = URLSessionConfiguration.default
        cache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 100_000_000)
        config.urlCache = cache
        config.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: config)
    }
    
    private func rateLimit() async {
        await serializer.proceed()
    }
    
    private func request<T: Codable>(_ endpoint: String, queryItems: [URLQueryItem] = []) async throws -> T {
        await rateLimit()
        
        guard var components = URLComponents(string: "\(baseURL)\(endpoint)") else {
            throw AppError.network(TMDBError.invalidURL)
        }
        
        var items = queryItems
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        
        // Add language and region from LocalizationManager
        let localizationManager = await LocalizationManager.shared
        let language = localizationManager.currentLanguage.id // e.g., "it", "en"
        let region = localizationManager.currentCountry.id // e.g., "IT", "US"
        
        // Combine language and region in TMDb format (e.g., "it-IT", "en-US")
        let languageParam = "\(language)-\(region)"
        
        items.append(URLQueryItem(name: "language", value: languageParam))
        items.append(URLQueryItem(name: "region", value: region))
        
        components.queryItems = items
        
        guard let url = components.url else {
            throw AppError.network(TMDBError.invalidURL)
        }
        
        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.network(TMDBError.invalidResponse)
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 429 {
                    print("⚠️ TMDB Rate Limit Exceeded! Backing off...")
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1s
                }
                print("❌ TMDB Error: \(httpResponse.statusCode) for \(endpoint)")
                throw AppError.network(TMDBError.httpError(httpResponse.statusCode))
            }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            // All errors from this service are considered network errors.
            // If it's already an AppError, we rethrow it to preserve its type.
            if error is AppError {
                throw error
            }
            print("❌ Decoding or Network Error for \(endpoint): \(error)")
            throw AppError.network(error)
        }
    }
    
    // MARK: - Movies
    
    func getTrendingMovies(timeWindow: TimeWindow = .week, page: Int = 1) async throws -> TMDBResponse<Movie> {
        try await request("/trending/movie/\(timeWindow.rawValue)", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    func getPopularMovies(page: Int = 1) async throws -> TMDBResponse<Movie> {
        try await request("/movie/popular", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    func getTopRatedMovies(page: Int = 1) async throws -> TMDBResponse<Movie> {
        try await request("/movie/top_rated", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    func discoverMovies(
        withGenre genreId: Int? = nil,
        sortBy: String = "popularity.desc",
        page: Int = 1,
        minRuntime: Int? = nil,
        maxRuntime: Int? = nil,
        minRating: Double? = nil,
        country: String? = nil
    ) async throws -> TMDBResponse<Movie> {
        var items = [
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        
        if let genreId = genreId {
            items.append(URLQueryItem(name: "with_genres", value: "\(genreId)"))
        }
        
        if let minRuntime = minRuntime {
            items.append(URLQueryItem(name: "with_runtime.gte", value: "\(minRuntime)"))
        }
        
        if let maxRuntime = maxRuntime {
            items.append(URLQueryItem(name: "with_runtime.lte", value: "\(maxRuntime)"))
        }
        
        if let minRating = minRating {
            items.append(URLQueryItem(name: "vote_average.gte", value: "\(minRating)"))
            // Only show movies with enough votes to be meaningful
            items.append(URLQueryItem(name: "vote_count.gte", value: "100"))
        }
        
        if let country = country {
            items.append(URLQueryItem(name: "with_origin_country", value: country))
        }
        
        return try await request("/discover/movie", queryItems: items)
    }
    
    func searchMovies(query: String, page: Int = 1) async throws -> TMDBResponse<Movie> {
        try await request("/search/movie", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    // MARK: - TV Shows
    
    func getTrendingTVShows(timeWindow: TimeWindow = .week, page: Int = 1) async throws -> TMDBResponse<TVShow> {
        try await request("/trending/tv/\(timeWindow.rawValue)", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    func getPopularTVShows(page: Int = 1) async throws -> TMDBResponse<TVShow> {
        try await request("/tv/popular", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    func getTopRatedTVShows(page: Int = 1) async throws -> TMDBResponse<TVShow> {
        try await request("/tv/top_rated", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    func discoverTVShows(
        withGenre genreId: Int? = nil,
        sortBy: String = "popularity.desc",
        page: Int = 1,
        minRating: Double? = nil,
        country: String? = nil
    ) async throws -> TMDBResponse<TVShow> {
        var items = [
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        
        if let genreId = genreId {
            items.append(URLQueryItem(name: "with_genres", value: "\(genreId)"))
        }
        
        if let minRating = minRating {
            items.append(URLQueryItem(name: "vote_average.gte", value: "\(minRating)"))
            // Only show shows with enough votes to be meaningful
            items.append(URLQueryItem(name: "vote_count.gte", value: "100"))
        }
        
        if let country = country {
            items.append(URLQueryItem(name: "with_origin_country", value: country))
        }
        
        return try await request("/discover/tv", queryItems: items)
    }
    
    func searchTVShows(query: String, page: Int = 1) async throws -> TMDBResponse<TVShow> {
        try await request("/search/tv", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    // MARK: - Multi Search
    
    func searchMulti(query: String, page: Int = 1) async throws -> TMDBMultiResponse {
        try await request("/search/multi", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    // MARK: - Movie Details
    
    func getMovieDetails(id: Int) async throws -> Movie {
        try await request("/movie/\(id)")
    }
    
    func getMovieCredits(id: Int) async throws -> Credits {
        try await request("/movie/\(id)/credits")
    }
    
    func getMovieVideos(id: Int) async throws -> TMDBVideosResponse {
        try await request("/movie/\(id)/videos")
    }
    
    func getMovieWatchProviders(id: Int) async throws -> WatchProvider {
        try await request("/movie/\(id)/watch/providers")
    }
    
    func getSimilarMovies(id: Int, page: Int = 1) async throws -> TMDBResponse<Movie> {
        try await request("/movie/\(id)/similar", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    // MARK: - TV Details
    
    func getTVShowDetails(id: Int) async throws -> TVShow {
        try await request("/tv/\(id)")
    }
    
    func getTVShowCredits(id: Int) async throws -> Credits {
        try await request("/tv/\(id)/credits")
    }
    
    func getTVShowVideos(id: Int) async throws -> TMDBVideosResponse {
        try await request("/tv/\(id)/videos")
    }
    
    func getTVShowWatchProviders(id: Int) async throws -> WatchProvider {
        try await request("/tv/\(id)/watch/providers")
    }
    
    func getSimilarTVShows(id: Int, page: Int = 1) async throws -> TMDBResponse<TVShow> {
        try await request("/tv/\(id)/similar", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }
    
    // MARK: - External IDs
    
    func getMovieExternalIds(id: Int) async throws -> ExternalIds {
        try await request("/movie/\(id)/external_ids")
    }
    
    func getTVShowExternalIds(id: Int) async throws -> ExternalIds {
        try await request("/tv/\(id)/external_ids")
    }
    
    // MARK: - People
    
    func getPersonDetails(id: Int) async throws -> PersonDetails {
        try await request("/person/\(id)")
    }
    
    func getPersonCombinedCredits(id: Int) async throws -> PersonCombinedCredits {
        try await request("/person/\(id)/combined_credits")
    }
}

struct TMDBVideosResponse: Codable {
    let results: [Video]
}

struct TMDBMultiResponse: Codable {
    let page: Int
    let results: [SearchResult]
    let totalPages: Int
    let totalResults: Int
    
    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}

struct SearchResult: Codable, Identifiable, Hashable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, overview, title, name
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
    
    var displayTitle: String {
        title ?? name ?? "Unknown"
    }
    
    var year: String? {
        if let releaseDate = releaseDate {
            return String(releaseDate.prefix(4))
        } else if let firstAirDate = firstAirDate {
            return String(firstAirDate.prefix(4))
        }
        return nil
    }
    
    var posterURL: URL? {
        guard let posterPath = posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
    
    var rating: String {
        guard let voteAverage = voteAverage else { return "N/A" }
        return String(format: "%.1f", voteAverage)
    }
}

enum TimeWindow: String {
    case day
    case week
}

enum TMDBError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        }
    }
}
