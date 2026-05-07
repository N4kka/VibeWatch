import Foundation

/// Service for harvesting movies and TV shows from TMDB API
actor TMDBHarvester {
    private let apiKey: String
    private let baseURL = "https://api.themoviedb.org/3"
    private let session: URLSession

    // Rate limiting: TMDB allows ~40 requests/10 seconds
    private var lastRequestTime: Date = .distantPast
    private let minRequestInterval: TimeInterval = 0.25  // 4 requests/second

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Movie Harvesting

    /// Fetch popular movies from TMDB
    func fetchPopularMovies(page: Int = 1) async throws -> TMDBMovieListResponse {
        let url = "\(baseURL)/movie/popular?api_key=\(apiKey)&page=\(page)&language=en-US"
        return try await fetch(url)
    }

    /// Fetch top-rated movies from TMDB
    func fetchTopRatedMovies(page: Int = 1) async throws -> TMDBMovieListResponse {
        let url = "\(baseURL)/movie/top_rated?api_key=\(apiKey)&page=\(page)&language=en-US"
        return try await fetch(url)
    }

    /// Fetch trending movies (week)
    func fetchTrendingMovies(page: Int = 1) async throws -> TMDBMovieListResponse {
        let url = "\(baseURL)/trending/movie/week?api_key=\(apiKey)&page=\(page)"
        return try await fetch(url)
    }

    /// Fetch now playing movies
    func fetchNowPlayingMovies(page: Int = 1) async throws -> TMDBMovieListResponse {
        let url = "\(baseURL)/movie/now_playing?api_key=\(apiKey)&page=\(page)&language=en-US"
        return try await fetch(url)
    }

    /// Fetch upcoming movies
    func fetchUpcomingMovies(page: Int = 1) async throws -> TMDBMovieListResponse {
        let url = "\(baseURL)/movie/upcoming?api_key=\(apiKey)&page=\(page)&language=en-US"
        return try await fetch(url)
    }

    // MARK: - TV Show Harvesting

    /// Fetch popular TV shows from TMDB
    func fetchPopularTVShows(page: Int = 1) async throws -> TMDBTVListResponse {
        let url = "\(baseURL)/tv/popular?api_key=\(apiKey)&page=\(page)&language=en-US"
        return try await fetch(url)
    }

    /// Fetch top-rated TV shows from TMDB
    func fetchTopRatedTVShows(page: Int = 1) async throws -> TMDBTVListResponse {
        let url = "\(baseURL)/tv/top_rated?api_key=\(apiKey)&page=\(page)&language=en-US"
        return try await fetch(url)
    }

    /// Fetch trending TV shows (week)
    func fetchTrendingTVShows(page: Int = 1) async throws -> TMDBTVListResponse {
        let url = "\(baseURL)/trending/tv/week?api_key=\(apiKey)&page=\(page)"
        return try await fetch(url)
    }

    // MARK: - Video/Clip Fetching

    /// Fetch videos (trailers, clips) for a movie
    func fetchMovieVideos(movieId: Int) async throws -> TMDBVideosResponse {
        let url = "\(baseURL)/movie/\(movieId)/videos?api_key=\(apiKey)&language=en-US"
        return try await fetch(url)
    }

    /// Fetch videos (trailers, clips) for a TV show
    func fetchTVShowVideos(tvShowId: Int) async throws -> TMDBVideosResponse {
        let url = "\(baseURL)/tv/\(tvShowId)/videos?api_key=\(apiKey)&language=en-US"
        return try await fetch(url)
    }

    // MARK: - Bulk Harvesting

    /// Harvest movies from multiple sources
    func harvestMovies(
        count: Int,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [TMDBMovie] {
        var movies: [TMDBMovie] = []
        var seenIds: Set<Int> = []

        let sources: [(String, (Int) async throws -> TMDBMovieListResponse)] = [
            ("trending", fetchTrendingMovies),
            ("popular", fetchPopularMovies),
            ("top_rated", fetchTopRatedMovies),
            ("now_playing", fetchNowPlayingMovies),
            ("upcoming", fetchUpcomingMovies)
        ]

        outer: for (sourceName, fetchFunc) in sources {
            var page = 1
            while movies.count < count {
                do {
                    let response = try await fetchFunc(page)

                    for movie in response.results {
                        guard !seenIds.contains(movie.id) else { continue }
                        seenIds.insert(movie.id)
                        movies.append(movie)
                        progress(movies.count, count)

                        if movies.count >= count {
                            break outer
                        }
                    }

                    // No more pages
                    if page >= response.totalPages {
                        print("  [\(sourceName)] Exhausted at page \(page)")
                        break
                    }

                    page += 1
                } catch {
                    print("  [\(sourceName)] Error on page \(page): \(error.localizedDescription)")
                    break
                }
            }
        }

        return movies
    }

    /// Harvest TV shows from multiple sources
    func harvestTVShows(
        count: Int,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [TMDBTVShow] {
        var shows: [TMDBTVShow] = []
        var seenIds: Set<Int> = []

        let sources: [(String, (Int) async throws -> TMDBTVListResponse)] = [
            ("trending", fetchTrendingTVShows),
            ("popular", fetchPopularTVShows),
            ("top_rated", fetchTopRatedTVShows)
        ]

        outer: for (sourceName, fetchFunc) in sources {
            var page = 1
            while shows.count < count {
                do {
                    let response = try await fetchFunc(page)

                    for show in response.results {
                        guard !seenIds.contains(show.id) else { continue }
                        seenIds.insert(show.id)
                        shows.append(show)
                        progress(shows.count, count)

                        if shows.count >= count {
                            break outer
                        }
                    }

                    if page >= response.totalPages {
                        print("  [\(sourceName)] Exhausted at page \(page)")
                        break
                    }

                    page += 1
                } catch {
                    print("  [\(sourceName)] Error on page \(page): \(error.localizedDescription)")
                    break
                }
            }
        }

        return shows
    }

    // MARK: - Private Helpers

    private func fetch<T: Decodable>(_ urlString: String) async throws -> T {
        // Rate limiting
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minRequestInterval {
            try await Task.sleep(nanoseconds: UInt64((minRequestInterval - elapsed) * 1_000_000_000))
        }
        lastRequestTime = Date()

        guard let url = URL(string: urlString) else {
            throw HarvesterError.invalidURL(urlString)
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HarvesterError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw HarvesterError.httpError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HarvesterError.decodingError(error)
        }
    }
}

enum HarvesterError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        }
    }
}
