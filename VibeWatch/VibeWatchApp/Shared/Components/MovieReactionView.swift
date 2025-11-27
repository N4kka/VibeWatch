import SwiftUI

struct MovieReactionView: View {
    let mediaId: Int
    let mediaType: MediaType
    
    @StateObject private var reactionService = MovieReactionService.shared
    @EnvironmentObject var authService: AuthService
    @State private var counts: MovieReactionCounts?
    @State private var userReaction: ReactionType?
    @State private var isLoading = false
    
    private var userId: String {
        authService.currentUser?.id ?? getDeviceId()
    }
    
    var body: some View {
        HStack(spacing: 24) {
            // Like button
            Button(action: { toggleReaction(.like) }) {
                HStack(spacing: 8) {
                    Image(systemName: userReaction == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(userReaction == .like ? .blue : .theme.textSecondary)
                    
                    Text("\(counts?.likeCount ?? 0)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(userReaction == .like ? .blue : .theme.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(userReaction == .like ? Color.blue.opacity(0.1) : Color.white.opacity(0.05))
                )
            }
            .disabled(isLoading)
            
            // Dislike button
            Button(action: { toggleReaction(.dislike) }) {
                HStack(spacing: 8) {
                    Image(systemName: userReaction == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(userReaction == .dislike ? .orange : .theme.textSecondary)
                    
                    Text("\(counts?.dislikeCount ?? 0)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(userReaction == .dislike ? .orange : .theme.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(userReaction == .dislike ? Color.orange.opacity(0.1) : Color.white.opacity(0.05))
                )
            }
            .disabled(isLoading)
            
            // Percentage indicator (if there are reactions)
            if let counts = counts, counts.totalReactions > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(counts.likePercentage)%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Text("liked")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .task {
            await loadReactions()
        }
        .onChange(of: mediaId) { _ in
            Task { await loadReactions() }
        }
    }
    
    // MARK: - Actions
    
    private func loadReactions() async {
        do {
            // Load counts
            counts = try await reactionService.getReactionCounts(mediaId: mediaId, mediaType: mediaType)
            
            // Load user's reaction
            userReaction = try await reactionService.getUserReaction(mediaId: mediaId, mediaType: mediaType, userId: userId)
        } catch {
            print("❌ [MovieReactionView] Error loading reactions: \(error)")
            ErrorHandler.shared.logOnly(error, context: "Load reactions")
        }
    }
    
    private func toggleReaction(_ reaction: ReactionType) {
        guard !isLoading else { return }
        
        Task {
            isLoading = true
            defer { isLoading = false }
            
            do {
                // Toggle reaction
                try await reactionService.toggleReaction(
                    mediaId: mediaId,
                    mediaType: mediaType,
                    reaction: reaction,
                    userId: userId
                )
                
                // Reload to get updated counts
                await loadReactions()
                
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
            } catch {
                print("❌ [MovieReactionView] Error toggling reaction: \(error)")
                ErrorHandler.shared.handle(error, context: "Toggle reaction")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func getDeviceId() -> String {
        let key = "deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// MARK: - Preview

struct MovieReactionView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            MovieReactionView(mediaId: 238, mediaType: .movie)
            MovieReactionView(mediaId: 1396, mediaType: .tv)
        }
        .padding()
        .background(Color.theme.background)
    }
}
