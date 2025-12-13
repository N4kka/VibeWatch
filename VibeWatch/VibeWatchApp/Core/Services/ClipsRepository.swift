import Foundation

/// Data layer responsible for fetching clips from various sources.
@MainActor
class ClipsRepository {
    private let database: DatabaseClipsService
    private let cache: ContentCacheManager
    
    init(database: DatabaseClipsService = .shared, cache: ContentCacheManager = .shared) {
        self.database = database
        self.cache = cache
    }
    
    func fetchClips(count: Int) async throws -> [Clip] {
        // First, try to get clips from the local database
        let dbClips = try await database.fetchPersonalizedClips(count: count)
        if !dbClips.isEmpty {
            return dbClips
        }
        
        // As a fallback, try the content cache (which might have pre-loaded clips)
        let cachedClips = cache.cachedClips
        if !cachedClips.isEmpty {
            return Array(cachedClips.prefix(count))
        }
        
        // If all else fails, return an empty array or throw an error
        return []
    }
}
