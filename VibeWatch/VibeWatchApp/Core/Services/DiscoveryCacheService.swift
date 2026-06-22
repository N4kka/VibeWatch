import Foundation
import Supabase

/// Service for caching Discovery content in local SQLite database (offline-first!)
/// Caches movies/TV for 24 hours, refreshes at midnight
@MainActor
class DiscoveryCacheService {
    static let shared = DiscoveryCacheService()
    
    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared
    private let tmdbService = TMDBService.shared
    
    // Cache in-memory for ultra-fast access
    private var cachedMovies: [Movie] = []
    private var cachedPopularMovies: [Movie] = []
    private var cachedTopRatedMovies: [Movie] = []
    private var cachedTVShows: [TVShow] = []
    private var lastCacheUpdate: Date?
    
    private init() {}
    
    // MARK: - Public API
    
    /// Get discovery content (from cache if available, SQLite DB if not, TMDB as fallback)
    func getDiscoveryContent() async throws -> (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow]) {
        // Step 1: Check in-memory cache (instant!)
        if let lastUpdate = lastCacheUpdate,
           Date().timeIntervalSince(lastUpdate) < 3600, // 1 hour
           !cachedMovies.isEmpty {
            // Ensure daily randomization still happens even when served from memory
            if shouldRandomizeToday() {
                cachedMovies.shuffle()
                cachedPopularMovies.shuffle()
                cachedTopRatedMovies.shuffle()
                cachedTVShows.shuffle()
                updateLastRandomizationDate()
                Logger.debug("[DiscoveryCache] Randomized in-memory cache for today")
            }

            Logger.debug("[DiscoveryCache] Using in-memory cache")
            return (cachedMovies, cachedPopularMovies, cachedTopRatedMovies, cachedTVShows)
        }

        // Step 2: Try local SQLite database cache (offline-capable!)
        if let cached = try? await fetchFromLocalDatabase() {
            Logger.debug("[DiscoveryCache] Using local SQLite cache")
            cacheInMemory(cached)
            return cached
        }

        // Step 3: Fallback to TMDB with error handling
        Logger.debug("[DiscoveryCache] Fetching fresh from TMDB and caching...")
        do {
            let fresh = try await fetchFromTMDB()

            // Save to local database in background
            Task.detached(priority: .background) {
                await self.saveToLocalDatabase(fresh)
            }

            cacheInMemory(fresh)
            return fresh
        } catch {
            Logger.warning("[DiscoveryCache] Failed to fetch from TMDB: \(error.localizedDescription)")

            // If network fails, try to return stale cache (even if expired)
            if let staleCache = try? await fetchFromLocalDatabase(ignoreExpiration: true) {
                Logger.debug("[DiscoveryCache] Using stale cache as fallback")
                cacheInMemory(staleCache)
                return staleCache
            }

            // If all else fails, throw the error
            throw error
        }
    }
    
    /// Force refresh from TMDB (call at midnight or on user request)
    func refreshContent() async throws {
        Logger.debug("[DiscoveryCache] Force refreshing from TMDB...")
        let fresh = try await fetchFromTMDB()
        await saveToLocalDatabase(fresh)
        cacheInMemory(fresh)
    }
    
    /// Check if cache needs refresh (older than 24 hours)
    func needsRefresh() async -> Bool {
        do {
            let rows = try await db.queryRaw("""
                SELECT cached_at FROM discovery_cache
                WHERE deleted_at IS NULL
                ORDER BY cached_at DESC
                LIMIT 1
            """)
            
            guard let latestRow = rows.first,
                  let cachedAtString = latestRow["cached_at"] as? String else {
                return true
            }
            
            let formatter = ISO8601DateFormatter()
            guard let cachedAt = formatter.date(from: cachedAtString) else {
                return true
            }
            
            let age = Date().timeIntervalSince(cachedAt)
            return age > 86400 // 24 hours
        } catch {
            Logger.warning("[DiscoveryCache] Failed to check cache age: \(error)")
            return true
        }
    }
    
    // MARK: - Local SQLite Database Operations
    
    private func fetchFromLocalDatabase(ignoreExpiration: Bool = false) async throws -> (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow])? {
        // Fetch all cached content from local SQLite
        let response: [[String: Any]]

        if ignoreExpiration {
            // Fetch even expired cache (for offline fallback)
            response = try await db.queryRaw("""
                SELECT * FROM discovery_cache
                WHERE deleted_at IS NULL
                ORDER BY cached_at DESC
            """)
        } else {
            // Fetch only non-expired cache
            let now = ISO8601DateFormatter().string(from: Date())
            response = try await db.queryRaw("""
                SELECT * FROM discovery_cache
                WHERE expires_at > ? AND deleted_at IS NULL
            """, parameters: [now])
        }
        
        guard !response.isEmpty else {
            Logger.debug("[DiscoveryCache] Local cache is empty or expired")
            return nil
        }
        
        // Check if we should randomize today (once daily)
        let shouldRandomize = shouldRandomizeToday()
        
        // Parse into categories
        var trendingMovies: [Movie] = []
        var popularMovies: [Movie] = []
        var topRatedMovies: [Movie] = []
        var trendingTV: [TVShow] = []
        
        for row in response {
            guard let contentType = row["content_type"] as? String,
                  let tmdbId = row["tmdb_id"] as? Int,
                  let title = row["title"] as? String else {
                continue
            }
            
            switch contentType {
            case "trending_movies":
                trendingMovies.append(parseMovie(from: row, id: tmdbId, title: title))
            case "popular_movies":
                popularMovies.append(parseMovie(from: row, id: tmdbId, title: title))
            case "top_rated_movies":
                topRatedMovies.append(parseMovie(from: row, id: tmdbId, title: title))
            case "trending_tv":
                trendingTV.append(parseTVShow(from: row, id: tmdbId, title: title))
            default:
                break
            }
        }
        
        // Randomize if needed (daily)
        if shouldRandomize {
            trendingMovies.shuffle()
            popularMovies.shuffle()
            topRatedMovies.shuffle()
            trendingTV.shuffle()
            updateLastRandomizationDate()
            Logger.debug("[DiscoveryCache] Randomized all content for today")
        }
        
        Logger.debug("[DiscoveryCache] Retrieved from local SQLite: \(trendingMovies.count) trending, \(popularMovies.count) popular, \(topRatedMovies.count) top rated, \(trendingTV.count) TV")
        
        return (trendingMovies, popularMovies, topRatedMovies, trendingTV)
    }
    
    // Parse Movie from SQLite row
    private func parseMovie(from row: [String: Any], id: Int, title: String) -> Movie {
        let genresString = row["genres"] as? String ?? "[]"
        let genresData = genresString.data(using: .utf8) ?? Data()
        let genres = (try? JSONDecoder().decode([Int].self, from: genresData)) ?? []
        
        return Movie(
            id: id,
            title: title,
            overview: row["overview"] as? String ?? "",
            posterPath: row["poster_path"] as? String ?? "",
            backdropPath: row["backdrop_path"] as? String ?? "",
            releaseDate: row["release_date"] as? String ?? "",
            voteAverage: row["vote_average"] as? Double ?? 0.0,
            voteCount: 0,
            genreIds: genres,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0.0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
    
    // Parse TVShow from SQLite row
    private func parseTVShow(from row: [String: Any], id: Int, title: String) -> TVShow {
        let genresString = row["genres"] as? String ?? "[]"
        let genresData = genresString.data(using: .utf8) ?? Data()
        let genres = (try? JSONDecoder().decode([Int].self, from: genresData)) ?? []
        
        return TVShow(
            id: id,
            name: title,
            overview: row["overview"] as? String ?? "",
            posterPath: row["poster_path"] as? String ?? "",
            backdropPath: row["backdrop_path"] as? String ?? "",
            firstAirDate: row["release_date"] as? String ?? "",
            voteAverage: row["vote_average"] as? Double ?? 0.0,
            voteCount: 0,
            genreIds: genres,
            genres: nil,
            originalLanguage: "",
            popularity: 0.0,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil,
            numberOfSeasons: nil,
            episodeRunTime: nil,
            lastAirDate: nil,
            numberOfEpisodes: nil,
            inProduction: nil,
            seasons: nil,
            nextEpisodeToAir: nil
        )
    }

    // MARK: - Daily Randomization Logic
    
    private func shouldRandomizeToday() -> Bool {
        let key = "lastDiscoveryRandomization"
        guard let lastRandomization = UserDefaults.standard.object(forKey: key) as? Date else {
            return true // Never randomized before
        }
        
        let calendar = Calendar.current
        return !calendar.isDate(lastRandomization, inSameDayAs: Date())
    }
    
    private func updateLastRandomizationDate() {
        let key = "lastDiscoveryRandomization"
        UserDefaults.standard.set(Date(), forKey: key)
    }
    
    private func saveToLocalDatabase(_ content: (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow])) async {
        Logger.debug("[DiscoveryCache] Saving to local SQLite...")
        
        do {
            // Clear old cache first
            _ = try await db.queryRaw("DELETE FROM discovery_cache")
            Logger.debug("[DiscoveryCache] Cleared old local cache")
            
            // Helper to convert genre IDs array to JSON string
            let genresToJSON = { (genres: [Int]?) -> String in
                guard let genres = genres,
                      let data = try? JSONEncoder().encode(genres),
                      let string = String(data: data, encoding: .utf8) else {
                    return "[]"
                }
                return string
            }
            
            let now = Date()
            let expiresAt = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            let formatter = ISO8601DateFormatter()
            
            // Insert trending movies
            for movie in content.trending {
                let values: [String: Any] = [
                    "id": UUID().uuidString,
                    "content_type": "trending_movies",
                    "tmdb_id": movie.id,
                    "title": movie.title,
                    "overview": movie.overview,
                    "poster_path": movie.posterPath ?? "",
                    "backdrop_path": movie.backdropPath ?? "",
                    "vote_average": movie.voteAverage,
                    "release_date": movie.releaseDate ?? "",
                    "genres": genresToJSON(movie.genreIds),
                    "cached_at": formatter.string(from: now),
                    "expires_at": formatter.string(from: expiresAt)
                ]
                _ = try await db.insert("discovery_cache", values: values)
            }
            
            // Insert popular movies
            for movie in content.popular {
                let values: [String: Any] = [
                    "id": UUID().uuidString,
                    "content_type": "popular_movies",
                    "tmdb_id": movie.id,
                    "title": movie.title,
                    "overview": movie.overview,
                    "poster_path": movie.posterPath ?? "",
                    "backdrop_path": movie.backdropPath ?? "",
                    "vote_average": movie.voteAverage,
                    "release_date": movie.releaseDate ?? "",
                    "genres": genresToJSON(movie.genreIds),
                    "cached_at": formatter.string(from: now),
                    "expires_at": formatter.string(from: expiresAt)
                ]
                _ = try await db.insert("discovery_cache", values: values)
            }
            
            // Insert top rated movies
            for movie in content.topRated {
                let values: [String: Any] = [
                    "id": UUID().uuidString,
                    "content_type": "top_rated_movies",
                    "tmdb_id": movie.id,
                    "title": movie.title,
                    "overview": movie.overview,
                    "poster_path": movie.posterPath ?? "",
                    "backdrop_path": movie.backdropPath ?? "",
                    "vote_average": movie.voteAverage,
                    "release_date": movie.releaseDate ?? "",
                    "genres": genresToJSON(movie.genreIds),
                    "cached_at": formatter.string(from: now),
                    "expires_at": formatter.string(from: expiresAt)
                ]
                _ = try await db.insert("discovery_cache", values: values)
            }
            
            // Insert trending TV shows
            for tv in content.tv {
                let values: [String: Any] = [
                    "id": UUID().uuidString,
                    "content_type": "trending_tv",
                    "tmdb_id": tv.id,
                    "title": tv.name,
                    "overview": tv.overview,
                    "poster_path": tv.posterPath ?? "",
                    "backdrop_path": tv.backdropPath ?? "",
                    "vote_average": tv.voteAverage,
                    "release_date": tv.firstAirDate ?? "",
                    "genres": genresToJSON(tv.genreIds),
                    "cached_at": formatter.string(from: now),
                    "expires_at": formatter.string(from: expiresAt)
                ]
                _ = try await db.insert("discovery_cache", values: values)
            }
            
            let totalItems = content.trending.count + content.popular.count + content.topRated.count + content.tv.count
            Logger.debug("[DiscoveryCache] Saved \(totalItems) items to local SQLite")
            
        } catch {
            Logger.error("[DiscoveryCache] Failed to save to local database: \(error)")
        }
    }
    
    private func fetchFromTMDB() async throws -> (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow]) {
        // Retry with exponential backoff (max 3 attempts)
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                // Fetch all in parallel for speed
                async let trending = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
                async let popular = tmdbService.getPopularMovies(page: 1)
                async let topRated = tmdbService.getTopRatedMovies(page: 1)
                async let tv = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)

                let (trendingRes, popularRes, topRatedRes, tvRes) = try await (trending, popular, topRated, tv)

                Logger.debug("[DiscoveryCache] Fetched from TMDB: \(trendingRes.results.count) trending, \(popularRes.results.count) popular, \(topRatedRes.results.count) top rated, \(tvRes.results.count) TV")

                return (trendingRes.results, popularRes.results, topRatedRes.results, tvRes.results)
            } catch {
                lastError = error
                Logger.warning("[DiscoveryCache] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")

                // Don't retry on the last attempt
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1)) // 1s, 2s, 4s
                    Logger.debug("[DiscoveryCache] Retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All attempts failed, throw the last error
        throw lastError ?? NSError(domain: "DiscoveryCacheService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch from TMDB after \(maxAttempts) attempts"])
    }
    
    // MARK: - In-Memory Cache
    
    private func cacheInMemory(_ content: (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow])) {
        cachedMovies = content.trending
        cachedPopularMovies = content.popular
        cachedTopRatedMovies = content.topRated
        cachedTVShows = content.tv
        lastCacheUpdate = Date()
    }
}

// MARK: - Database Models

struct DiscoveryCacheRow: Codable {
    let id: UUID
    let contentType: String
    let tmdbId: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let genres: [Int]?
    let cachedAt: Date
    let expiresAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, title, overview, genres
        case contentType = "content_type"
        case tmdbId = "tmdb_id"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case cachedAt = "cached_at"
        case expiresAt = "expires_at"
    }
    
    func toMovie() -> Movie {
        Movie(
            id: tmdbId,
            title: title,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate,
            voteAverage: voteAverage ?? 0.0,
            voteCount: 0,
            genreIds: genres,
            genres: nil,
            adult: false,
            originalLanguage: "en",
            popularity: 0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
    
    func toTVShow() -> TVShow {
        TVShow(
            id: tmdbId,
            name: title,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            firstAirDate: releaseDate,
            voteAverage: voteAverage ?? 0.0,
            voteCount: 0,
            genreIds: genres,
            genres: nil,
            originalLanguage: "en",
            popularity: 0,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil,
            numberOfSeasons: nil,
            episodeRunTime: nil,
            lastAirDate: nil,
            numberOfEpisodes: nil,
            inProduction: nil,
            seasons: nil,
            nextEpisodeToAir: nil
        )
    }
}

struct DiscoveryCacheInsert: Codable {
    let contentType: String
    let tmdbId: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let genres: [Int]?
    
    enum CodingKeys: String, CodingKey {
        case title, overview, genres
        case contentType = "content_type"
        case tmdbId = "tmdb_id"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
    }
}
