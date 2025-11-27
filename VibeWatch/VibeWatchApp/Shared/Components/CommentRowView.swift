import SwiftUI

/// Displays a single comment with user info, like button, and reply functionality
struct CommentRowView: View {
    let comment: ClipComment
    let userId: String
    let onLikeTap: () -> Void
    let onReplyTap: () -> Void
    let onDeleteTap: (() -> Void)?
    
    @State private var showDeleteConfirm = false
    
    init(
        comment: ClipComment,
        userId: String,
        onLikeTap: @escaping () -> Void,
        onReplyTap: @escaping () -> Void,
        onDeleteTap: (() -> Void)? = nil
    ) {
        self.comment = comment
        self.userId = userId
        self.onLikeTap = onLikeTap
        self.onReplyTap = onReplyTap
        self.onDeleteTap = onDeleteTap
    }
    
    // Use computed properties instead of state to reflect current comment data
    private var isLiked: Bool {
        comment.isLiked
    }
    
    private var likeCount: Int {
        comment.likeCount
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            avatarView
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Username and time
                HStack(spacing: 6) {
                    Text(comment.userDisplayName ?? "User")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    
                    Text(comment.timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Delete button (only for own comments)
                    if comment.userId == userId {
                        Menu {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(4)
                        }
                    }
                }
                
                // Comment text
                Text(comment.displayContent)
                    .font(.body)
                    .foregroundColor(comment.isDeleted ? .secondary : .primary)
                    .italic(comment.isDeleted)
                
                // Actions
                if !comment.isDeleted {
                    HStack(spacing: 20) {
                        // Like button
                        Button(action: handleLikeTap) {
                            HStack(spacing: 4) {
                                Image(systemName: isLiked ? "heart.fill" : "heart")
                                    .font(.subheadline)
                                    .foregroundColor(isLiked ? .red : .secondary)
                                
                                if likeCount > 0 {
                                    Text("\(likeCount)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // Reply button
                        Button(action: onReplyTap) {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.right")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if comment.replyCount > 0 {
                                    Text("\(comment.replyCount)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Delete Comment",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDeleteTap?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this comment? This action cannot be undone.")
        }
    }
    
    private var avatarView: some View {
        Group {
            if let avatarURL = comment.userAvatarURL, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        placeholderAvatar
                    @unknown default:
                        placeholderAvatar
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                placeholderAvatar
            }
        }
    }
    
    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
    }
    
    private func handleLikeTap() {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        
        // Call actual action (parent will handle state updates)
        onLikeTap()
    }
}

// MARK: - Preview

#Preview("Regular Comment") {
    VStack(spacing: 0) {
        CommentRowView(
            comment: ClipComment(
                id: "1",
                clipId: "clip-1",
                userId: "user-1",
                parentCommentId: nil,
                content: "This is an amazing clip! Really enjoyed watching it. 🔥",
                likeCount: 5,
                replyCount: 2,
                createdAt: Date().addingTimeInterval(-3600)
            ),
            userId: "user-2",
            onLikeTap: { print("Liked") },
            onReplyTap: { print("Reply") }
        )
        
        Divider()
        
        CommentRowView(
            comment: ClipComment(
                id: "2",
                clipId: "clip-1",
                userId: "user-2",
                parentCommentId: nil,
                content: "Great work!",
                likeCount: 12,
                replyCount: 0,
                createdAt: Date().addingTimeInterval(-7200)
            ),
            userId: "user-2",
            onLikeTap: { print("Liked") },
            onReplyTap: { print("Reply") },
            onDeleteTap: { print("Delete") }
        )
    }
    .background(Color.theme.background)
}

#Preview("Deleted Comment") {
    CommentRowView(
        comment: ClipComment(
            id: "3",
            clipId: "clip-1",
            userId: "user-1",
            parentCommentId: nil,
            content: "This was deleted",
            likeCount: 0,
            replyCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: Date()
        ),
        userId: "user-2",
        onLikeTap: { print("Liked") },
        onReplyTap: { print("Reply") }
    )
    .background(Color.theme.background)
}
