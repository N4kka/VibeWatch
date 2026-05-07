import SwiftUI

/// Displays a list of comments for a clip with reply functionality
struct CommentsListView: View {
    let clipId: String
    let userId: String
    let analyticsContext: AnalyticsContext?
    var onCountsChange: ((Int) -> Void)? = nil
    
    @State private var comments: [ClipComment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var replyingTo: ClipComment?
    @State private var expandedComments: Set<String> = []
    @State private var commentReplies: [String: [ClipComment]] = [:]

    init(
        clipId: String,
        userId: String,
        analyticsContext: AnalyticsContext? = nil,
        onCountsChange: ((Int) -> Void)? = nil
    ) {
        self.clipId = clipId
        self.userId = userId
        self.analyticsContext = analyticsContext
        self.onCountsChange = onCountsChange
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("clips.comments".localized)
                    .font(.headline)
                    .foregroundColor(.white)
                
                if !comments.isEmpty {
                    Text("(\(comments.count))")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            // Content
            if isLoading && comments.isEmpty {
                loadingView
            } else if let error = errorMessage, comments.isEmpty {
                errorView(error)
            } else if comments.isEmpty {
                emptyView
            } else {
                commentsList
            }
            
            Divider()
            
            // Input (either reply or new comment)
            if let replyComment = replyingTo {
                CommentInputView(
                    clipId: clipId,
                    userId: userId,
                    parentCommentId: replyComment.id,
                    analyticsContext: analyticsContext,
                    onCommentPosted: { newReply in
                        handleReplyPosted(newReply, to: replyComment)
                    },
                    onCancel: {
                        replyingTo = nil
                    }
                )
            } else {
                CommentInputView(
                    clipId: clipId,
                    userId: userId,
                    parentCommentId: nil,
                    analyticsContext: analyticsContext,
                    onCommentPosted: { newComment in
                        handleCommentPosted(newComment)
                    }
                )
            }
        }
        .task {
            await loadComments()
        }
    }
    
    private var commentsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(comments) { comment in
                    VStack(spacing: 0) {
                        // Main comment
                        CommentRowView(
                            comment: comment,
                            userId: userId,
                            onLikeTap: {
                                Task {
                                    await toggleCommentLike(comment)
                                }
                            },
                            onReplyTap: {
                                replyingTo = comment
                            },
                            onDeleteTap: comment.userId == userId ? {
                                Task {
                                    await deleteComment(comment)
                                }
                            } : nil
                        )
                        
                        // Show replies button
                        if comment.replyCount > 0 {
                            Button(action: {
                                toggleReplies(for: comment)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: expandedComments.contains(comment.id) ? "chevron.up" : "chevron.down")
                                        .font(.caption)
                                    
                                    Text(expandedComments.contains(comment.id) ? "clips.hideReplies".localized : "\(String(format: "clips.viewReplies".localized, comment.replyCount))")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.blue)
                                .padding(.leading, 60)
                                .padding(.vertical, 8)
                            }
                        }
                        
                        // Replies
                        if expandedComments.contains(comment.id) {
                            if let replies = commentReplies[comment.id] {
                                ForEach(replies) { reply in
                                    HStack(spacing: 0) {
                                        // Indent indicator
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .frame(width: 2)
                                            .padding(.leading, 44)
                                        
                                        CommentRowView(
                                            comment: reply,
                                            userId: userId,
                                            onLikeTap: {
                                                Task {
                                                    await toggleCommentLike(reply)
                                                }
                                            },
                                            onReplyTap: {
                                                replyingTo = comment
                                            },
                                            onDeleteTap: reply.userId == userId ? {
                                                Task {
                                                    await deleteReply(reply, from: comment)
                                                }
                                            } : nil
                                        )
                                    }
                                }
                            }
                        }
                        
                        Divider()
                    }
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("clips.comments.loading".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("common.tryAgain".localized) {
                Task {
                    await loadComments()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            
            Text("clips.noComments".localized)
                .font(.headline)
            
            Text("clips.beFirstToComment".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Actions
    
    private func loadComments() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let loadedComments = try await ClipCommentService.shared.getComments(
                clipId: clipId,
                userId: userId
            )
            
            await MainActor.run {
                comments = loadedComments
                isLoading = false
            }
            
            notifyCountChange()
            
            Logger.info("[CommentsList] Loaded \(loadedComments.count) comments")
            
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load comments"
                isLoading = false
            }
            
            Logger.error("[CommentsList] Failed to load comments: \(error)")
        }
    }
    
    private func handleCommentPosted(_ comment: ClipComment) {
        withAnimation {
            comments.insert(comment, at: 0)
        }
        notifyCountChange()
    }
    
    private func handleReplyPosted(_ reply: ClipComment, to parent: ClipComment) {
        // Add reply to the replies dictionary
        if commentReplies[parent.id] != nil {
            commentReplies[parent.id]?.append(reply)
        } else {
            commentReplies[parent.id] = [reply]
        }
        
        // Update parent's reply count
        if let index = comments.firstIndex(where: { $0.id == parent.id }) {
            var updatedComment = comments[index]
            updatedComment.replyCount += 1
            comments[index] = updatedComment
        }
        notifyCountChange()
        
        // Expand replies if not already
        if !expandedComments.contains(parent.id) {
            expandedComments.insert(parent.id)
        }
        
        // Clear reply state
        replyingTo = nil
    }
    
    private func toggleReplies(for comment: ClipComment) {
        if expandedComments.contains(comment.id) {
            expandedComments.remove(comment.id)
        } else {
            expandedComments.insert(comment.id)
            
            // Load replies if not already loaded
            if commentReplies[comment.id] == nil {
                Task {
                    await loadReplies(for: comment)
                }
            }
        }
    }
    
    private func loadReplies(for comment: ClipComment) async {
        do {
            let replies = try await ClipCommentService.shared.getReplies(
                parentId: comment.id,
                userId: userId
            )
            
            await MainActor.run {
                commentReplies[comment.id] = replies
            }
            
            Logger.info("[CommentsList] Loaded \(replies.count) replies for comment \(comment.id)")
            
        } catch {
            Logger.error("[CommentsList] Failed to load replies: \(error)")
        }
    }
    
    private func toggleCommentLike(_ comment: ClipComment) async {
        do {
            let isNowLiked = try await ClipCommentService.shared.toggleCommentLike(
                commentId: comment.id,
                userId: userId,
                context: analyticsContext
            )
            
            // Update the comment in the list on main thread with animation
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                        var updatedComment = comments[index]
                        updatedComment.isLiked = isNowLiked
                        updatedComment.likeCount += isNowLiked ? 1 : -1
                        comments[index] = updatedComment
                    }
                    
                    // Also update in replies if present
                    for (parentId, replies) in commentReplies {
                        if let replyIndex = replies.firstIndex(where: { $0.id == comment.id }) {
                            var updatedReplies = replies
                            var updatedReply = updatedReplies[replyIndex]
                            updatedReply.isLiked = isNowLiked
                            updatedReply.likeCount += isNowLiked ? 1 : -1
                            updatedReplies[replyIndex] = updatedReply
                            commentReplies[parentId] = updatedReplies
                        }
                    }
                }
            }
            
            Logger.info("[CommentsList] Toggled like for comment \(comment.id)")
            
        } catch {
            await MainActor.run {
                errorMessage = "Failed to like comment. Please try again."
            }
            Logger.error("[CommentsList] Failed to toggle comment like: \(error)")
        }
    }
    
    private func deleteComment(_ comment: ClipComment) async {
        do {
            try await ClipCommentService.shared.deleteComment(
                commentId: comment.id,
                userId: userId,
                context: analyticsContext
            )
            
            await MainActor.run {
                withAnimation {
                    comments.removeAll { $0.id == comment.id }
                }
            }
            notifyCountChange()
            
            Logger.info("[CommentsList] Deleted comment \(comment.id)")
            
        } catch {
            Logger.error("[CommentsList] Failed to delete comment: \(error)")
            
            await MainActor.run {
                errorMessage = "Failed to delete comment"
            }
        }
    }
    
    private func deleteReply(_ reply: ClipComment, from parent: ClipComment) async {
        do {
            try await ClipCommentService.shared.deleteComment(
                commentId: reply.id,
                userId: userId,
                context: analyticsContext
            )
            
            await MainActor.run {
                withAnimation {
                    commentReplies[parent.id]?.removeAll { $0.id == reply.id }
                    
                    // Update parent's reply count
                    if let index = comments.firstIndex(where: { $0.id == parent.id }) {
                        var updatedComment = comments[index]
                        updatedComment.replyCount = max(0, updatedComment.replyCount - 1)
                        comments[index] = updatedComment
                    }
                }
            }
            notifyCountChange()
            
            Logger.info("[CommentsList] Deleted reply \(reply.id)")
            
        } catch {
            Logger.error("[CommentsList] Failed to delete reply: \(error)")
            
            await MainActor.run {
                errorMessage = "Failed to delete reply"
            }
        }
    }
    
    private func notifyCountChange() {
        let total = comments.reduce(0) { partial, comment in
            partial + 1 + comment.replyCount
        }
        onCountsChange?(total)
    }
}

// MARK: - Preview

#Preview {
    CommentsListView(
        clipId: "clip-123",
        userId: "user-456"
    )
    .background(Color.theme.background)
}
