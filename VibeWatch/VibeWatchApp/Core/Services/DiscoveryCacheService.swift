import Foundation
import Supabase

/// Service for caching Discovery content in Supabase database
/// Caches movies/TV for 24 hours, refreshes at midnight
@MainActor
class DiscoveryCacheService {
    static let shared = DiscoveryCacheService()
    
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
    
    /// Get discovery content (from cache if available, DB if not, TMDB as fallback)
    func getDiscoveryContent() async throws -> (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow]) {
        // Step 1: Check in-memory cache (instant!)
        if let lastUpdate = lastCacheUpdate,
           Date().timeIntervalSince(lastUpdate) < 3600, // 1 hour
           !cachedMovies.isEmpty {
            print("⚡️ [DiscoveryCache] Using in-memory cache")
            return (cachedMovies, cachedPopularMovies, cachedTopRatedMovies, cachedTVShows)
        }
        
        // Step 2: Try database cache
        if let cached = try? await fetchFromDatabase() {
            print("📊 [DiscoveryCache] Using database cache")
            cacheInMemory(cached)
            return cached
        }
        
        // Step 3: Fallback to TMDB and save to cache
        print("🔄 [DiscoveryCache] Fetching fresh from TMDB and caching...")
        let fresh = try await fetchFromTMDB()
        
        // Save to database in background
        Task.detached(priority: .background) {
            await self.saveToDatabase(fresh)
        }
        
        cacheInMemory(fresh)
        return fresh
    }
    
    /// Force refresh from TMDB (call at midnight or on user request)
    func refreshContent() async throws {
        print("🔄 [DiscoveryCache] Force refreshing from TMDB...")
        let fresh = try await fetchFromTMDB()
        await saveToDatabase(fresh)
        cacheInMemory(fresh)
    }
    
    /// Check if cache needs refresh (older than 24 hours)
    func needsRefresh() async -> Bool {
        guard let client = supabase.client else { return true }
        
        do {
            // Check if any cached item is older than 24 hours
            let response: [DiscoveryCacheRow] = try await client
                .from("discovery_cache")
                .select("cached_at")
                .order("cached_at", ascending: false)
                .limit(1)
                .execute()
                .value
            
            guard let latest = response.first else { return true }
            
            let age = Date().timeIntervalSince(latest.cachedAt)
            return age > 86400 // 24 hours
        } catch {
            print("⚠️ [DiscoveryCache] Failed to check cache age: \(error)")
            return true
        }
    }
    
    // MARK: - Database Operations
    
    private func fetchFromDatabase() async throws -> (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow])? {
        guard let client = supabase.client else {
            print("⚠️ [DiscoveryCache] Supabase not configured")
            return nil
        }
        
        // Fetch all cached content that's not expired
        let response: [DiscoveryCacheRow] = try await client
            .from("discovery_cache")
            .select()
            .gt("expires_at", value: Date())
            .execute()
            .value
        
        guard !response.isEmpty else {
            print("📭 [DiscoveryCache] Cache is empty or expired")
            return nil
        }
        
        // Parse into categories
        let trendingMovies = response
            .filter { $0.contentType == "trending_movies" }
            .map { $0.toMovie() }
        
        let popularMovies = response
            .filter { $0.contentType == "popular_movies" }
            .map { $0.toMovie() }
        
        let topRatedMovies = response
            .filter { $0.contentType == "top_rated_movies" }
            .map { $0.toMovie() }
        
        let trendingTV = response
            .filter { $0.contentType == "trending_tv" }
            .map { $0.toTVShow() }
        
        print("✅ [DiscoveryCache] Retrieved from DB: \(trendingMovies.count) trending, \(popularMovies.count) popular, \(topRatedMovies.count) top rated, \(trendingTV.count) TV")
        
        return (trendingMovies, popularMovies, topRatedMovies, trendingTV)
    }
    
    private func saveToDatabase(_ content: (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow])) async {
        guard let client = supabase.client else {
            print("⚠️ [DiscoveryCache] Supabase not configured, skipping save")
            return
        }
        
        do {
            // Clear old cache first
            try await client
                .from("discovery_cache")
                .delete()
                .execute()
            
            print("🗑️ [DiscoveryCache] Cleared old cache")
            
            // Prepare rows for insertion
            var rows: [DiscoveryCacheInsert] = []
            
            // Add trending movies
            rows += content.trending.map { movie in
                DiscoveryCacheInsert(
                    contentType: "trending_movies",
                    tmdbId: movie.id,
                    title: movie.title,
                    overview: movie.overview,
                    posterPath: movie.posterPath,
                    backdropPath: movie.backdropPath,
                    voteAverage: movie.voteAverage,
                    releaseDate: movie.releaseDate,
                    genres: movie.genreIds
                )
            }
            
            // Add popular movies
            rows += content.popular.map { movie in
                DiscoveryCacheInsert(
                    contentType: "popular_movies",
                    tmdbId: movie.id,
                    title: movie.title,
                    overview: movie.overview,
                    posterPath: movie.posterPath,
                    backdropPath: movie.backdropPath,
                    voteAverage: movie.voteAverage,
                    releaseDate: movie.releaseDate,
                    genres: movie.genreIds
                )
            }
            
            // Add top rated movies
            rows += content.topRated.map { movie in
                DiscoveryCacheInsert(
                    contentType: "top_rated_movies",
                    tmdbId: movie.id,
                    title: movie.title,
                    overview: movie.overview,
                    posterPath: movie.posterPath,
                    backdropPath: movie.backdropPath,
                    voteAverage: movie.voteAverage,
                    releaseDate: movie.releaseDate,
                    genres: movie.genreIds
                )
            }
            
            // Add trending TV shows
            rows += content.tv.map { tv in
                DiscoveryCacheInsert(
                    contentType: "trending_tv",
                    tmdbId: tv.id,
                    title: tv.name,
                    overview: tv.overview,
                    posterPath: tv.posterPath,
                    backdropPath: tv.backdropPath,
                    voteAverage: tv.voteAverage,
                    releaseDate: tv.firstAirDate,
                    genres: tv.genreIds
                )
            }
            
            // Insert all at once
            try await client
                .from("discovery_cache")
                .insert(rows)
                .execute()
            
            print("✅ [DiscoveryCache] Saved \(rows.count) items to database")
            
        } catch {
            print("❌ [DiscoveryCache] Failed to save to database: \(error)")
        }
    }
    
    private func fetchFromTMDB() async throws -> (trending: [Movie], popular: [Movie], topRated: [Movie], tv: [TVShow]) {
        // Fetch all in parallel for speed
        async let trending = tmdbService.getTrendingMovies(timeWindow: .week, page: 1)
        async let popular = tmdbService.getPopularMovies(page: 1)
        async let topRated = tmdbService.getTopRatedMovies(page: 1)
        async let tv = tmdbService.getTrendingTVShows(timeWindow: .week, page: 1)
        
        let (trendingRes, popularRes, topRatedRes, tvRes) = try await (trending, popular, topRated, tv)
        
        print("✅ [DiscoveryCache] Fetched from TMDB: \(trendingRes.results.count) trending, \(popularRes.results.count) popular, \(topRatedRes.results.count) top rated, \(tvRes.results.count) TV")
        
        return (trendingRes.results, popularRes.results, topRatedRes.results, tvRes.results)
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
            imdbId: nil
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
