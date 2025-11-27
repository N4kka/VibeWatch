import SwiftUI

/// Input field for posting comments on clips
struct CommentInputView: View {
    let clipId: String
    let userId: String
    let parentCommentId: String?
    let onCommentPosted: (ClipComment) -> Void
    let onCancel: (() -> Void)?
    
    @State private var commentText = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool
    
    private let maxCharacters = 500
    
    init(
        clipId: String,
        userId: String,
        parentCommentId: String? = nil,
        onCommentPosted: @escaping (ClipComment) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.clipId = clipId
        self.userId = userId
        self.parentCommentId = parentCommentId
        self.onCommentPosted = onCommentPosted
        self.onCancel = onCancel
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Reply indicator
            if parentCommentId != nil {
                HStack {
                    Text("Replying...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("Cancel") {
                        onCancel?()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 16)
            }
            
            // Input field
            HStack(alignment: .bottom, spacing: 12) {
                // Text field
                TextField(
                    parentCommentId != nil ? "Write a reply..." : "Add a comment...",
                    text: $commentText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(20)
                .focused($isFocused)
                .disabled(isPosting)
                .lineLimit(1...6)
                
                // Post button
                Button(action: postComment) {
                    if isPosting {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(canPost ? .blue : .gray)
                    }
                }
                .disabled(!canPost || isPosting)
            }
            .padding(.horizontal, 16)
            
            // Character count
            if !commentText.isEmpty {
                HStack {
                    Spacer()
                    Text("\(commentText.count)/\(maxCharacters)")
                        .font(.caption2)
                        .foregroundColor(commentText.count > maxCharacters ? .red : .secondary)
                }
                .padding(.horizontal, 16)
            }
            
            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color.theme.background)
        .onAppear {
            isFocused = true
        }
    }
    
    private var canPost: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        commentText.count <= maxCharacters &&
        !isPosting
    }
    
    private func postComment() {
        guard canPost else { return }
        
        let trimmedText = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        Task {
            isPosting = true
            errorMessage = nil
            
            do {
                let comment = try await ClipCommentService.shared.postComment(
                    clipId: clipId,
                    userId: userId,
                    content: trimmedText,
                    parentId: parentCommentId
                )
                
                await MainActor.run {
                    commentText = ""
                    isPosting = false
                    isFocused = false
                    onCommentPosted(comment)
                }
                
                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                
            } catch {
                await MainActor.run {
                    isPosting = false
                    errorMessage = "Failed to post comment. Please try again."
                    print("❌ [CommentInput] Failed to post comment: \(error)")
                }
                
                // Error haptic
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Preview

#Preview("Top-Level Comment") {
    VStack {
        Spacer()
        CommentInputView(
            clipId: "clip-123",
            userId: "user-456",
            parentCommentId: nil,
            onCommentPosted: { comment in
                print("Posted comment: \(comment.id)")
            }
        )
    }
    .background(Color.black)
}

#Preview("Reply") {
    VStack {
        Spacer()
        CommentInputView(
            clipId: "clip-123",
            userId: "user-456",
            parentCommentId: "comment-789",
            onCommentPosted: { comment in
                print("Posted reply: \(comment.id)")
            },
            onCancel: {
                print("Cancelled reply")
            }
        )
    }
    .background(Color.black)
}
