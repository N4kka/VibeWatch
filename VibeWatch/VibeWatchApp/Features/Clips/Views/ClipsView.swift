import SwiftUI
import AVKit
import WebKit

struct ClipsView: View {
    @StateObject private var viewModel = ClipsViewModel()
    @State private var currentIndex = 0
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        ZStack {
            if viewModel.isLoading && viewModel.clips.isEmpty {
                loadingView
            } else if viewModel.clips.isEmpty {
                emptyStateView
            } else {
                clipsScrollView
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await viewModel.loadClips()
        }
        .onDisappear {
            // Pause all clips when leaving the Clips tab
            NotificationCenter.default.post(name: .pauseAllClips, object: nil)
        }
        .onChange(of: scenePhase) {
            // Pause all clips when app goes to background
            if scenePhase != .active {
                NotificationCenter.default.post(name: .pauseAllClips, object: nil)
            }
        }
    }
    
    private var clipsScrollView: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.clips.enumerated()), id: \.element.id) { index, clip in
                            ClipPlayerView(
                                clip: clip,
                                isCurrentClip: currentIndex == index,
                                onBecomeVisible: {
                                    currentIndex = index
                                },
                                onLikeToggle: { isLiked in
                                    viewModel.toggleLike(for: clip.id, isLiked: isLiked)
                                }
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(index)
                            .onAppear {
                                // Smart pagination: Load more when 5 clips away from end
                                let remainingClips = viewModel.clips.count - index - 1
                                if remainingClips <= 5 {
                                    Task {
                                        await viewModel.loadMoreClips()
                                    }
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
                .onAppear {
                    proxy.scrollTo(0, anchor: .top)
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.5)
            
            Text("clips.loadingClips".localized)
                .font(.system(size: 16))
                .foregroundColor(.white)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("clips.noClipsAvailable".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            
            Text("clips.noClipsDescription".localized)
                .font(.system(size: 16))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

struct ClipPlayerView: View {
    let clip: Clip
    let isCurrentClip: Bool
    let onBecomeVisible: () -> Void
    let onLikeToggle: (Bool) -> Void
    
    @State private var isLiked: Bool
    @State private var likeCount: Int
    @State private var showComments = false
    @State private var showAddToList = false
    @State private var hasAppeared = false
    @State private var showControls = false
    @State private var controlsTimer: Timer?
    
    // Engagement tracking
    @StateObject private var engagementTracker = UserEngagementTracker.shared
    @State private var watchStartTime: Date?
    @State private var accumulatedWatchTime: TimeInterval = 0
    
    init(clip: Clip, isCurrentClip: Bool, onBecomeVisible: @escaping () -> Void, onLikeToggle: @escaping (Bool) -> Void) {
        self.clip = clip
        self.isCurrentClip = isCurrentClip
        self.onBecomeVisible = onBecomeVisible
        self.onLikeToggle = onLikeToggle
        _isLiked = State(initialValue: clip.isLiked)
        _likeCount = State(initialValue: clip.likes)
    }
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VerticalYouTubePlayer(
                clipId: clip.id,
                videoId: clip.videoId,
                shouldPlay: isCurrentClip && hasAppeared
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        handleTap()
                    }
            )
            
            // Action buttons on the right
            VStack(alignment: .trailing, spacing: 20) {
                Spacer()
                
                ClipActionButton(
                    icon: isLiked ? "heart.fill" : "heart",
                    count: likeCount,
                    color: isLiked ? .red : .white
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isLiked.toggle()
                        likeCount = isLiked ? likeCount + 1 : likeCount - 1
                        onLikeToggle(isLiked)
                    }
                }
                
                ClipActionButton(
                    icon: "message",
                    count: clip.comments,
                    color: .white
                ) {
                    showComments = true
                }
                
                ClipActionButton(
                    icon: "plus",
                    text: "clips.addToList".localized,
                    color: .white
                ) {
                    showAddToList = true
                }
                
                ClipActionButton(
                    icon: "square.and.arrow.up",
                    color: .white
                ) {
                    shareClip()
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, showControls ? 200 : 100)
            .animation(.easeInOut(duration: 0.2), value: showControls)
            
            // Title and description on the left bottom
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(clip.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    
                    Text(clip.description)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, showControls ? 200 : 100)
            .padding(.trailing, 80)
            .animation(.bouncy, value: showControls)
        }
        .onAppear {
            hasAppeared = true
            onBecomeVisible()
            
            // Start tracking watch time
            watchStartTime = Date()
            engagementTracker.startWatchingClip(clip)
        }
        .onDisappear {
            hasAppeared = false
            controlsTimer?.invalidate()
            
            // End tracking and save engagement data
            if let startTime = watchStartTime {
                let watchDuration = Date().timeIntervalSince(startTime) + accumulatedWatchTime
                // Assuming average clip is 60 seconds (we don't have actual duration yet)
                engagementTracker.updateWatchTime(clipId: clip.id, duration: watchDuration, totalDuration: 60)
                engagementTracker.endWatchingClip(clipId: clip.id, genres: [], actors: [])
            }
            
            watchStartTime = nil
            accumulatedWatchTime = 0
        }
        .sheet(isPresented: $showComments) {
            CommentsView(clipId: clip.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showAddToList) {
            AddToListView(
                movieId: clip.movieId,
                tvShowId: clip.tvShowId,
                mediaType: clip.movieId != nil ? .movie : .tv
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
    }
    
    private func handleTap() {
        // Invalidate existing timer
        controlsTimer?.invalidate()
        
        // Show controls
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
        
        // Hide controls after 3 seconds
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = false
            }
        }
    }
    
    private func shareClip() {
        let activityVC = UIActivityViewController(
            activityItems: [URL(string: clip.videoURL)!],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

struct VerticalYouTubePlayer: UIViewRepresentable {
    let clipId: String  // UNIQUE identifier for each clip (includes movie ID)
    let videoId: String // YouTube video ID (can be duplicate across clips)
    let shouldPlay: Bool
    
    // CRITICAL: Shared WebView pool to prevent multiple instances
    private static var webViewPool: [WKWebView] = []
    private static let maxPoolSize = 3
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        // Reuse existing WebView from pool if available
        let webView: WKWebView
        if let pooledView = Self.webViewPool.first {
            webView = pooledView
            Self.webViewPool.removeFirst()
            print("♻️ Reusing WebView from pool (remaining: \(Self.webViewPool.count))")
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.allowsPictureInPictureMediaPlayback = false
            
            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.scrollView.isScrollEnabled = false
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.backgroundColor = .black
            webView.scrollView.bounces = false
            webView.scrollView.alwaysBounceVertical = false
            webView.scrollView.alwaysBounceHorizontal = false
            print("🆕 Created new WebView")
        }
        
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop any playing video immediately
        webView.evaluateJavaScript("if (typeof player !== 'undefined') { player.stopVideo(); player.destroy(); }")
        
        // Return to pool if not full
        if webViewPool.count < maxPoolSize {
            webViewPool.append(webView)
            print("🔄 Returned WebView to pool (pool size: \(webViewPool.count))")
        } else {
            print("🗑️ Pool full, disposing WebView")
        }
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // CRITICAL: Always stop first to prevent audio bleeding
        if !shouldPlay {
            // Not current clip - IMMEDIATELY stop all playback
            webView.evaluateJavaScript("if (typeof player !== 'undefined') { player.stopVideo(); player.mute(); }")
            return
        }
        
        // Use clipId (unique) instead of just videoId to prevent audio bugs
        if context.coordinator.currentClipId != clipId {
            print("🎬 Loading new clip: \(clipId)")
            
            // IMPORTANT: Stop and destroy any existing player IMMEDIATELY
            webView.evaluateJavaScript("if (typeof player !== 'undefined') { player.stopVideo(); player.mute(); player.destroy(); }")
            
            context.coordinator.currentClipId = clipId
            context.coordinator.currentVideoId = videoId
            context.coordinator.hasInitiallyPlayed = false
            
            // Small delay to ensure cleanup before loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.loadVideo(in: webView)
            }
            return
        }
        
        // This clip should play
        if !context.coordinator.hasInitiallyPlayed {
            // Initial play after loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                webView.evaluateJavaScript("if (typeof player !== 'undefined' && player.unMute && player.playVideo) { player.unMute(); player.playVideo(); }") { _, error in
                    if error == nil {
                        context.coordinator.hasInitiallyPlayed = true
                    }
                }
            }
        }
    }
    
    private func loadVideo(in webView: WKWebView) {
        let embedHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; overflow: hidden; -webkit-user-select: none; -webkit-touch-callout: none; }
                html, body { width: 100%; height: 100%; background: #000; }
                #player-container { position: relative; width: 100%; height: 100%; background: #000; }
                #player { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); width: 100vw; height: 177.78vw; max-height: 100vh; pointer-events: auto; }
            </style>
        </head>
        <body>
            <div id="player-container"><div id="player"></div></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
                var player;
                function onYouTubeIframeAPIReady() {
                    player = new YT.Player('player', {
                        height: '100%', width: '100%', videoId: '\(videoId)',
                        playerVars: { 'playsinline': 1, 'autoplay': 1, 'mute': 0, 'loop': 1, 'playlist': '\(videoId)', 'controls': 1, 'showinfo': 1, 'rel': 0, 'fs': 1, 'modestbranding': 1, 'iv_load_policy': 3, 'cc_load_policy': 1, 'enablejsapi': 1, 'origin': window.location.origin },
                        events: { 'onReady': function(e) { console.log('Ready'); }, 'onStateChange': function(e) { if (e.data === YT.PlayerState.ENDED) player.playVideo(); } }
                    });
                }
                document.addEventListener('contextmenu', function(e) { e.preventDefault(); });
            </script>
        </body>
        </html>
        """
        webView.loadHTMLString(embedHTML, baseURL: URL(string: "https://www.vibewatch.app"))
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: VerticalYouTubePlayer
        var currentClipId: String?      // Unique clip identifier
        var currentVideoId: String?     // YouTube video ID
        var hasInitiallyPlayed = false
        
        init(_ parent: VerticalYouTubePlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if url.scheme == "youtube" || url.host?.contains("youtube.com") == true && navigationAction.navigationType == .linkActivated {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}

struct ClipActionButton: View {
    let icon: String
    var count: Int?
    var text: String?
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 44, height: 44)
                
                if let count = count {
                    Text(formatCount(count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                } else if let text = text {
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
    }
    
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

struct CommentsView: View {
    let clipId: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var commentText = ""
    @State private var comments: [Comment] = []
    @State private var replyingTo: Comment?
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        ZStack(alignment: .top) {
            Color.theme.backgroundDark.opacity(0.98)
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    
                    Text("\(totalCommentsCount) clips.comment\(totalCommentsCount == 1 ? "" : "clips.comments")".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.theme.backgroundDark.opacity(0.98))
                
                Divider()
                    .background(Color.gray.opacity(0.3))
                
                // Comments List
                if comments.isEmpty {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        
                        Text("clips.noComments".localized)
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                        
                        Text("clips.beFirstToComment".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach($comments) { $comment in
                                CommentRow(
                                    comment: $comment,
                                    onReply: { comment in
                                        replyingTo = comment
                                        isInputFocused = true
                                    }
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                        .padding(.bottom, 80)
                    }
                }
                
                Spacer(minLength: 0)
            }
            
            // Comment Input - Fixed at bottom
            VStack {
                Spacer()
                
                VStack(spacing: 0) {
                    // Reply indicator - only show when keyboard is NOT focused
                    if let replyingTo = replyingTo, !isInputFocused {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\("clips.replyingTo".localized) \(replyingTo.username)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                
                                Text(replyingTo.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Button {
                                self.replyingTo = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.2))
                    }
                    
                    Divider()
                        .background(Color.gray.opacity(0.3))
                    
                    HStack(spacing: 12) {
                        // Avatar
                        if let avatarURL = appState.currentUser?.avatarURL,
                           let url = URL(string: avatarURL) {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.gray)
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.gray)
                                )
                        }
                        
                        // Input Field
                        HStack {
                            TextField(replyingTo != nil ? "clips.replyPlaceholder".localized : "clips.commentPlaceholder".localized, text: $commentText)
                                .font(.system(size: 15))
                                .foregroundColor(.white)
                                .tint(.white)
                                .focused($isInputFocused)
                                .submitLabel(.send)
                                .onSubmit {
                                    submitComment()
                                }
                            
                            if !commentText.isEmpty {
                                Button {
                                    submitComment()
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.theme.backgroundDark.opacity(0.98))
                }
            }
        }
        .onAppear {
            loadComments()
        }
    }
    
    private var totalCommentsCount: Int {
        comments.count + comments.reduce(0) { $0 + $1.replies.count }
    }
    
    private func loadComments() {
        // TODO: Load actual comments from backend
        comments = []
    }
    
    private func submitComment() {
        guard !commentText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        if let replyingTo = replyingTo {
            // Add as reply
            let reply = Reply(
                id: UUID().uuidString,
                userId: appState.currentUser?.id ?? "guest",
                username: appState.currentUser?.displayName ?? "Guest",
                avatarURL: appState.currentUser?.avatarURL,
                text: commentText,
                likes: 0,
                timestamp: Date()
            )
            
            if let index = comments.firstIndex(where: { $0.id == replyingTo.id }) {
                comments[index].replies.append(reply)
                comments[index].repliesCount = comments[index].replies.count
            }
            
            self.replyingTo = nil
        } else {
            // Add as new comment
            let newComment = Comment(
                id: UUID().uuidString,
                userId: appState.currentUser?.id ?? "guest",
                username: appState.currentUser?.displayName ?? "Guest",
                avatarURL: appState.currentUser?.avatarURL,
                text: commentText,
                likes: 0,
                timestamp: Date(),
                repliesCount: 0,
                replies: []
            )
            
            comments.insert(newComment, at: 0)
        }
        
        commentText = ""
        isInputFocused = false
        
        // TODO: Send comment/reply to backend
    }
}

struct CommentRow: View {
    @Binding var comment: Comment
    let onReply: (Comment) -> Void
    @State private var isLiked = false
    @State private var likeCount: Int
    @State private var showReplies = false
    
    init(comment: Binding<Comment>, onReply: @escaping (Comment) -> Void) {
        self._comment = comment
        self.onReply = onReply
        _likeCount = State(initialValue: comment.wrappedValue.likes)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Avatar
                if let avatarURL = comment.avatarURL, let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.gray)
                        )
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    // Username and time
                    HStack(spacing: 8) {
                        Text(comment.username)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text(timeAgoString(from: comment.timestamp))
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    
                    // Comment text
                    Text(comment.text)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // Actions
                    HStack(spacing: 20) {
                        Button {
                            onReply(comment)
                        } label: {
                            Text("clips.reply".localized)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.gray)
                        }
                        
                        if comment.repliesCount > 0 {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    showReplies.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(showReplies ? "clips.hideReplies" : "clips.viewReplies") \(comment.repliesCount) repl\(comment.repliesCount == 1 ? "y" : "ies")".localized)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.gray)
                                    
                                    Image(systemName: showReplies ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                
                Spacer()
                
                // Like button
                VStack(spacing: 4) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            isLiked.toggle()
                            likeCount = isLiked ? likeCount + 1 : likeCount - 1
                        }
                    } label: {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 18))
                            .foregroundColor(isLiked ? .red : .white)
                    }
                    
                    if likeCount > 0 {
                        Text("\(likeCount)")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }
                }
            }
            
            // Replies - with animation
            if showReplies && !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(comment.replies.sorted(by: { $0.timestamp > $1.timestamp })) { reply in
                        ReplyRow(reply: reply)
                    }
                }
                .padding(.leading, 52)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.second, .minute, .hour, .day, .weekOfYear], from: date, to: now)
        
        if let weeks = components.weekOfYear, weeks > 0 {
            return "\(weeks)w"
        } else if let days = components.day, days > 0 {
            return "\(days)d"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m"
        } else if let seconds = components.second, seconds > 0 {
            return "\(seconds)s"
        } else {
            return "now"
        }
    }
}

struct ReplyRow: View {
    let reply: Reply
    @State private var isLiked = false
    @State private var likeCount: Int
    
    init(reply: Reply) {
        self.reply = reply
        _likeCount = State(initialValue: reply.likes)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            if let avatarURL = reply.avatarURL, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    )
            }
            
            VStack(alignment: .leading, spacing: 4) {
                // Username and time
                HStack(spacing: 8) {
                    Text(reply.username)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text(timeAgoString(from: reply.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                
                // Reply text
                Text(reply.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            // Like button
            VStack(spacing: 2) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isLiked.toggle()
                        likeCount = isLiked ? likeCount + 1 : likeCount - 1
                    }
                } label: {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 16))
                        .foregroundColor(isLiked ? .red : .white)
                }
                
                if likeCount > 0 {
                    Text("\(likeCount)")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                }
            }
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.second, .minute, .hour, .day, .weekOfYear], from: date, to: now)
        
        if let weeks = components.weekOfYear, weeks > 0 {
            return "\(weeks)w"
        } else if let days = components.day, days > 0 {
            return "\(days)d"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m"
        } else if let seconds = components.second, seconds > 0 {
            return "\(seconds)s"
        } else {
            return "now"
        }
    }
}

struct AddToListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var listManager = ListManager.shared
    @StateObject private var listsViewModel = ListsViewModel()
    @State private var showCreateList = false
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: MediaType
    
    init(movieId: Int? = nil, tvShowId: Int? = nil, mediaType: MediaType = .movie) {
        self.movieId = movieId
        self.tvShowId = tvShowId
        self.mediaType = mediaType
    }
    
    private var availableLists: [MediaList] {
        listManager.lists.filter { list in
            list.type == .watchlist || list.type == .custom
        }
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    
                    Text("clips.addToList".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button {
                        dismiss()
                    } label: {
                        Text("common.done".localized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(UIColor.systemGray6).opacity(0.3))
                
                Divider()
                    .background(Color.gray.opacity(0.3))
                
                // Create New List Button
                Button {
                    showCreateList = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.orange)
                        
                        Text("clips.createNewList".localized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.orange)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color.orange.opacity(0.15))
                }
                
                Divider()
                    .background(Color.gray.opacity(0.3))
                
                // Lists
                if availableLists.isEmpty {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        
                        Text("clips.noListsYet".localized)
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                        
                        Text("clips.createFirstList".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(availableLists) { list in
                                ListSelectionRow(
                                    list: list,
                                    isSelected: isItemInList(list),
                                    onTap: {
                                        toggleListSelection(list)
                                    }
                                )
                                
                                if list.id != availableLists.last?.id {
                                    Divider()
                                        .background(Color.gray.opacity(0.3))
                                        .padding(.leading, 72)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateList) {
            CreateListView(viewModel: listsViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
    
    private func isItemInList(_ list: MediaList) -> Bool {
        let itemId = movieId ?? tvShowId ?? 0
        return list.items.contains { $0.mediaId == itemId }
    }
    
    private func toggleListSelection(_ list: MediaList) {
        let itemId = movieId ?? tvShowId ?? 0
        
        if isItemInList(list) {
            if let item = list.items.first(where: { $0.mediaId == itemId }) {
                listManager.removeFromList(listId: list.id, itemId: item.id)
            }
        } else {
            Task {
                do {
                    if mediaType == .movie, let movieId = movieId {
                        let movieDetails = try await TMDBService.shared.getMovieDetails(id: movieId)
                        listManager.addToList(listId: list.id, movie: movieDetails, mediaType: .movie)
                    } else if mediaType == .tv, let tvShowId = tvShowId {
                        let tvDetails = try await TMDBService.shared.getTVShowDetails(id: tvShowId)
                        let movie = Movie(
                            id: tvDetails.id,
                            title: tvDetails.name,
                            overview: tvDetails.overview,
                            posterPath: tvDetails.posterPath,
                            backdropPath: tvDetails.backdropPath,
                            releaseDate: tvDetails.firstAirDate,
                            voteAverage: tvDetails.voteAverage,
                            voteCount: tvDetails.voteCount,
                            genreIds: nil,
                            genres: nil,
                            adult: false,
                            originalLanguage: tvDetails.originalLanguage,
                            popularity: tvDetails.popularity,
                            runtime: nil,
                            status: nil,
                            tagline: nil,
                            productionCountries: nil,
                            imdbId: nil
                        )
                        listManager.addToList(listId: list.id, movie: movie, mediaType: .tv)
                    }
                    
                    dismiss()
                } catch {
                    print("Error adding to list: \(error)")
                }
            }
        }
    }
}

struct ListSelectionRow: View {
    let list: MediaList
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                if let firstItem = list.items.first,
                   let posterPath = firstItem.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w154\(posterPath)") {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                    .frame(width: 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 60)
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: 16))
                                .foregroundColor(.gray)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    
                    Text("\(list.items.count) \("common.items".localized)")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }
}

// Models
struct Comment: Identifiable, Codable {
    let id: String
    let userId: String
    let username: String
    let avatarURL: String?
    let text: String
    var likes: Int
    let timestamp: Date
    var repliesCount: Int
    var replies: [Reply]
}

struct Reply: Identifiable, Codable {
    let id: String
    let userId: String
    let username: String
    let avatarURL: String?
    let text: String
    var likes: Int
    let timestamp: Date
}

extension Notification.Name {
    static let pauseAllClips = Notification.Name("pauseAllClips")
}

#Preview {
    ClipsView()
        .environmentObject(AppState())
}
