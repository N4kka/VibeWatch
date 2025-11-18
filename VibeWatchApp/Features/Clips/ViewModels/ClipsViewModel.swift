import Foundation
import SwiftUI

/// Refactored ClipsViewModel - Instant loading, no wait time, proper deduplication
@MainActor
class ClipsViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let algorithm = SimplifiedClipsAlgorithm.shared
    private let engagementTracker = UserEngagementTracker.shared
    
    private var isLoadingMore = false
    
    // MARK: - Instant Loading (No Wait Time)
    
    /// Load clips INSTANTLY - no progressive loading, no wait time
    func loadClips() async {
        guard !isLoading else { return }
        
        print("⚡ INSTANT LOAD - User opened Clips view")
        isLoading = true
        errorMessage = nil
        
        // Reset deduplication for fresh session
        algorithm.resetDeduplication()
        
        do {
            // Fetch 30 clips instantly
            let fetchedClips = try await algorithm.generateFeed(count: 30)
            
            // Apply like status from local storage
            var processedClips = fetchedClips.map { clip in
                var updatedClip = clip
                updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                return updatedClip
            }
            
            // Filter by 3-minute max duration
            processedClips = processedClips.filter { $0.duration <= 180 }
            
            clips = processedClips
            
            print("✅ INSTANT LOAD complete: \(clips.count) clips ready")
            
            // Track clip impressions for user taste learning
            trackClipImpressions(processedClips)
            
        } catch {
            print("❌ Error loading clips: \(error)")
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    /// Refresh feed - reset and reload
    func refreshFeed() async {
        algorithm.resetDeduplication()
        clips = []
        await loadClips()
    }
    
    // MARK: - Infinite Scroll
    
    /// Load more clips when user scrolls to bottom
    func loadMoreClips() async {
        guard !isLoadingMore && !isLoading else { return }
        
        isLoadingMore = true
        
        do {
            // Fetch next batch (30 more clips, deduplicated)
            let moreClips = try await algorithm.loadMore(count: 30)
            
            // Apply like status
            var processedClips = moreClips.map { clip in
                var updatedClip = clip
                updatedClip.isLiked = ClipsService.shared.isClipLiked(clip.id)
                return updatedClip
            }
            
            // Filter by 3-minute max duration
            processedClips = processedClips.filter { $0.duration <= 180 }
            
            // Append to existing clips
            clips.append(contentsOf: processedClips)
            
            print("✅ Loaded \(processedClips.count) more clips. Total: \(clips.count)")
            
            // Track impressions
            trackClipImpressions(processedClips)
            
        } catch {
            print("❌ Error loading more: \(error)")
        }
        
        isLoadingMore = false
    }
    
    // MARK: - User Interaction Tracking (Taste Learning)
    
    /// Track when user starts watching a clip
    func startWatching(clip: Clip) {
        engagementTracker.startWatchingClip(clip)
        print("👁️ Started watching: \(clip.title)")
    }
    
    /// Track watch time and completion
    func updateWatchTime(clipId: String, watchedSeconds: Double, totalSeconds: Double) {
        engagementTracker.updateWatchTime(
            clipId: clipId,
            duration: watchedSeconds,
            totalDuration: totalSeconds
        )
    }
    
    /// Track when user leaves a clip
    func stopWatching(clipId: String) {
        engagementTracker.endWatchingClip(clipId: clipId)
        print("👋 Stopped watching clip")
    }
    
    /// Track when user likes a clip (interface for ClipsView)
    func toggleLike(for clipId: String, isLiked: Bool) {
        // Update UI immediately
        if let index = clips.firstIndex(where: { $0.id == clipId }) {
            var updatedClip = clips[index]
            updatedClip.isLiked = isLiked
            updatedClip.likes += isLiked ? 1 : -1
            clips[index] = updatedClip
            
            // Update service
            ClipsService.shared.updateLikeCount(clipId: clipId, newCount: updatedClip.likes)
            
            // Log for user taste learning
            if isLiked {
                print("❤️ Liked: \(updatedClip.title)")
            } else {
                print("💔 Unliked: \(updatedClip.title)")
            }
            
            // Persist like status
            Task {
                try? await ClipsService.shared.updateLikeStatus(clipId: clipId, isLiked: isLiked)
            }
        }
    }
    
    /// Track clip impressions (shown to user)
    private func trackClipImpressions(_ shownClips: [Clip]) {
        // Simple impression tracking - watch time is the primary signal
        print("📊 Showing \(shownClips.count) clips to user")
    }
    
    /// Track when user adds clip to list
    func trackAddToList(clip: Clip) {
        engagementTracker.trackListAddition(clip: clip, listType: "watchlist")
        print("📝 Added to list: \(clip.title)")
    }
    
    // MARK: - Utility
    
    /// Get algorithm stats for debugging
    func getStats() -> String {
        let (cached, shown) = algorithm.getStats()
        return "Cached: \(cached) | Shown: \(shown) | Current: \(clips.count)"
    }
}
