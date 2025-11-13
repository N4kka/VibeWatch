import Foundation

class TMDBService {
    static let shared = TMDBService()
    
    private let baseURL = "https://api.themoviedb.org/3"
    private let apiKey = "" // TODO: Add your TMDB API key here or use Config.swift
    private let session: URLSession
    private let cache: URLCache
    
    private let requestQueue = DispatchQueue(label: "com.vibewatch.tmdb.queue")
    private var lastRequestTime: Date?
    private let rateLimitInterval: TimeInterval = 0.25 // 4 requests per second (40 per 10s)
    
    private init() {
        let config = URLSessionConfiguration.default
        cache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 100_000_000)
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }
    
    private func rateLimit() async {
        await requestQueue.sync {
            if let lastTime = lastRequestTime {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed < rateLimitInterval {
                    Thread.sleep(forTimeInterval: rateLimitInterval - elapsed)
                }
            }
            lastRequestTime = Date()
        }
    }
    
    private func request<T: Codable>(_ endpoint: String, queryItems: [URLQueryItem] = []) async throws -> T {
        await rateLimit()
        
        guard var components = URLComponents(string: "\(baseURL)\(endpoint)") else {
            throw TMDBError.invalidURL
        }
        
        var items = queryItems
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        components.queryItems = items
        
        guard let url = components.url else {
            throw TMDBError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TMDBError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TMDBError.httpError(httpResponse.statusCode)
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingError(error)
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
    
    func discoverMovies(withGenre genreId: Int? = nil, sortBy: String = "popularity.desc", page: Int = 1) async throws -> TMDBResponse<Movie> {
        var items = [
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        
        if let genreId = genreId {
            items.append(URLQueryItem(name: "with_genres", value: "\(genreId)"))
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
    
    func discoverTVShows(withGenre genreId: Int? = nil, sortBy: String = "popularity.desc", page: Int = 1) async throws -> TMDBResponse<TVShow> {
        var items = [
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        
        if let genreId = genreId {
            items.append(URLQueryItem(name: "with_genres", value: "\(genreId)"))
        }
        
        return try await request("/discover/tv", queryItems: items)
    }
    
    func searchTVShows(query: String, page: Int = 1) async throws -> TMDBResponse<TVShow> {
        try await request("/search/tv", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "\(page)")
        ])
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
