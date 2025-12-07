import Foundation

struct ClipsSearchResult {
    let matches: [Clip]
    let related: [Clip]
}

/// Coordinates clip search and recommendation for the Clips search experience.
@MainActor
final class ClipsSearchService {
    static let shared = ClipsSearchService()
    
    private let databaseService: DatabaseClipsService
    private let tmdbService: TMDBServiceProtocol
    private let clipsService: ClipsService
    
    init(
        databaseService: DatabaseClipsService = .shared,
        tmdbService: TMDBServiceProtocol = TMDBService.shared,
        clipsService: ClipsService = .shared
    ) {
        self.databaseService = databaseService
        self.tmdbService = tmdbService
        self.clipsService = clipsService
    }
    
    func search(query: String, matchLimit: Int = 12, relatedLimit: Int = 30) async throws -> ClipsSearchResult {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else {
            return ClipsSearchResult(matches: [], related: [])
        }
        
        async let matchesTask = searchMatches(query: cleanedQuery, limit: matchLimit)
        async let relatedTask = fetchRelatedClips(query: cleanedQuery, limit: relatedLimit)
        
        let matches = await matchesTask
        let relatedRaw = await relatedTask
        let matchIds = Set(matches.map { $0.id })
        let related = relatedRaw.filter { !matchIds.contains($0.id) }
        
        return ClipsSearchResult(matches: matches, related: related)
    }
    
    // MARK: - Helpers
    
    private func searchMatches(query: String, limit: Int) async -> [Clip] {
        var results: [Clip] = []
        
        if let localMatches = try? await databaseService.searchClips(query: query, limit: limit) {
            results.append(contentsOf: localMatches)
        }
        
        if results.count < limit {
            let remaining = limit - results.count
            if let youtubeMatches = try? await clipsService.searchClips(query: query, limit: remaining + 5) {
                let existingIds = Set(results.map { $0.id })
                for clip in youtubeMatches where !existingIds.contains(clip.id) {
                    results.append(clip)
                    if results.count >= limit { break }
                }
            }
        }
        
        return Array(results.prefix(limit))
    }
    
    private func fetchRelatedClips(query: String, limit: Int) async -> [Clip] {
        var related: [Clip] = []
        
        if let searchResults = try? await tmdbService.searchMulti(query: query, page: 1) {
            let mediaItems = searchResults.results
                .filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
                .prefix(6)
                .map { result in
                    MediaItem(
                        id: result.id,
                        title: result.displayTitle,
                        isMovie: result.mediaType == "movie"
                    )
                }
            
            var relatedIds = Set<String>()
            for media in mediaItems {
                guard related.count < limit else { break }
                if let clips = try? await clipsService.clips(for: media, maxResults: 5) {
                    for clip in clips where !relatedIds.contains(clip.id) {
                        related.append(clip)
                        relatedIds.insert(clip.id)
                        if related.count >= limit { break }
                    }
                }
            }
        }
        
        if related.count < limit {
            let fallbackQuery = "\(query) movie clip"
            let existingIds = Set(related.map { $0.id })
            if let more = try? await clipsService.searchClips(query: fallbackQuery, limit: limit - related.count) {
                for clip in more where !existingIds.contains(clip.id) {
                    related.append(clip)
                    if related.count >= limit { break }
                }
            }
        }
        
        return Array(related.prefix(limit))
    }
}
