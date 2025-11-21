import Foundation

@MainActor
class ClipSegmenter {
    static let shared = ClipSegmenter()
    
    private let segmentDuration = 15 // seconds
    private let maxDisplayDuration = 30 // seconds - never show clips longer than 30s
    private let minUniqueSourcesBeforeSegments = 10 // require 10 unique sources before adding segments
    
    // Track unique source content (movie/TV show IDs)
    private var uniqueSourceIds = Set<String>()
    
    // Buffer to hold segments that will be added after we have 10+ unique sources
    private var segmentBuffer: [Clip] = []
    
    private init() {}
    
    /// Process a batch of clips: filter by duration, segment long clips, and manage the buffer
    func processClips(_ clips: [Clip]) -> [Clip] {
        print("🎬 Processing \(clips.count) clips...")
        
        var processedClips: [Clip] = []
        
        for clip in clips {
            // Skip clips longer than 30 seconds entirely
            guard clip.duration <= maxDisplayDuration else {
                print("⏭️ Skipping clip '\(clip.title)' - duration \(clip.duration)s exceeds max \(maxDisplayDuration)s")
                continue
            }
            
            // Track unique source (movie or TV show)
            let sourceId = getSourceId(clip)
            uniqueSourceIds.insert(sourceId)
            
            // If clip is already 15 seconds or less, use it as-is
            if clip.duration <= segmentDuration {
                processedClips.append(clip)
                print("✅ Added clip '\(clip.title)' (\(clip.duration)s) - already optimal length")
                continue
            }
            
            // Clip is 16-30 seconds - add the original clip AND create segments
            processedClips.append(clip)
            print("✅ Added original clip '\(clip.title)' (\(clip.duration)s)")
            
            // Generate 15-second segments from this clip
            let segments = createSegments(from: clip)
            print("🔪 Created \(segments.count) segments from '\(clip.title)'")
            
            // Add segments to buffer (will be released after 10 unique sources)
            segmentBuffer.append(contentsOf: segments)
        }
        
        print("📊 Unique sources so far: \(uniqueSourceIds.count)/\(minUniqueSourcesBeforeSegments)")
        print("📦 Segments in buffer: \(segmentBuffer.count)")
        
        // If we've reached 10+ unique sources, release buffered segments
        if uniqueSourceIds.count >= minUniqueSourcesBeforeSegments && !segmentBuffer.isEmpty {
            print("🎉 Threshold reached! Releasing \(segmentBuffer.count) buffered segments")
            processedClips.append(contentsOf: segmentBuffer)
            segmentBuffer.removeAll() // Clear buffer after releasing
        }
        
        print("✅ Final processed count: \(processedClips.count) clips")
        return processedClips
    }
    
    /// Create 15-second segments from a longer clip
    private func createSegments(from clip: Clip) -> [Clip] {
        var segments: [Clip] = []
        
        let numberOfSegments = clip.duration / segmentDuration
        
        for segmentIndex in 0..<numberOfSegments {
            let startTime = segmentIndex * segmentDuration
            let segmentId = "\(clip.id)_segment_\(segmentIndex)"
            
            let segment = Clip(
                id: segmentId,
                movieId: clip.movieId,
                tvShowId: clip.tvShowId,
                title: clip.title,
                description: clip.description,
                videoURL: clip.videoURL,
                videoId: clip.videoId,
                thumbnailURL: clip.thumbnailURL,
                duration: segmentDuration, // Always 15 seconds
                likes: 0, // Segments start with 0 likes
                comments: 0, // Segments start with 0 comments
                createdAt: clip.createdAt,
                isLiked: false,
                isSegment: true,
                originalClipId: clip.id,
                segmentIndex: segmentIndex,
                startTime: startTime
            )
            
            segments.append(segment)
        }
        
        return segments
    }
    
    /// Get a unique identifier for the source content (movie or TV show)
    private func getSourceId(_ clip: Clip) -> String {
        if let movieId = clip.movieId {
            return "movie_\(movieId)"
        } else if let tvShowId = clip.tvShowId {
            return "tv_\(tvShowId)"
        }
        return "unknown_\(clip.id)"
    }
    
    /// Reset the segmenter state (useful for testing or clearing cache)
    func reset() {
        uniqueSourceIds.removeAll()
        segmentBuffer.removeAll()
        print("🔄 ClipSegmenter reset")
    }
    
    /// Get current state information (for debugging)
    func getState() -> (uniqueSources: Int, bufferedSegments: Int) {
        return (uniqueSourceIds.count, segmentBuffer.count)
    }
}
