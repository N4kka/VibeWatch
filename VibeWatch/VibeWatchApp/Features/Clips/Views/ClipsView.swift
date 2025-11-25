import SwiftUI
import AVKit
import WebKit

struct ClipsView: View {
    @StateObject private var viewModel = ClipsViewModel()
    @StateObject private var quotaManager = DailyQuotaManager.shared
    @State private var currentIndex = 0
    @State private var showDailyPaywall = false
    @State private var showAccountGate = false
    @State private var navigateToDiscovery = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    
    // Interactive swipe navigation
    @State private var horizontalOffset: CGFloat = 0
    @State private var isDraggingHorizontally = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Left view - Discovery (visible when swiping right)
                if horizontalOffset > 0 {
                    DiscoveryView(selectedMovie: .constant(nil), selectedMediaType: .constant(.movie))
                        .offset(x: -geometry.size.width + horizontalOffset)
                }
                
                // Right view - Lists (visible when swiping left)
                if horizontalOffset < 0 {
                    ListsView()
                        .offset(x: geometry.size.width + horizontalOffset)
                }
                
                // Main content - Clips
                ZStack {
                    if viewModel.isLoading {
                        loadingView
                            .transition(.opacity)
                    } else if let error = viewModel.errorMessage {
                        errorView(error)
                            .transition(.opacity)
                    } else if viewModel.clips.isEmpty {
                        emptyStateView
                            .transition(.opacity)
                    } else {
                        clipsScrollView
                            .transition(.opacity)
                    }

                    if showAccountGate {
                        AccountCreationGateView(
                            isPresented: $showAccountGate,
                            onComeBack: {
                                NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
                            },
                            onAccountCreated: {
                                quotaManager.resetQuota()
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(101)
                    }

                    if showDailyPaywall {
                        DailyLimitPaywallView(isPresented: $showDailyPaywall, onComeBack: {
                            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
                        })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(100)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
                .animation(.easeInOut(duration: 0.3), value: viewModel.clips.isEmpty)
                .offset(x: horizontalOffset)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        let horizontalMovement = abs(value.translation.width)
                        let verticalMovement = abs(value.translation.height)
                        
                        // Start tracking horizontal if it's clearly more horizontal than vertical
                        if !isDraggingHorizontally && horizontalMovement > verticalMovement && horizontalMovement > 20 {
                            isDraggingHorizontally = true
                        }
                        
                        // Update offset if we're in horizontal drag mode
                        if isDraggingHorizontally {
                            horizontalOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        guard isDraggingHorizontally else { return }
                        
                        let threshold: CGFloat = geometry.size.width * 0.3
                        
                        if horizontalOffset > threshold {
                            // Swiped right - go to Discovery
                            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
                            horizontalOffset = 0
                            isDraggingHorizontally = false
                        } else if horizontalOffset < -threshold {
                            // Swiped left - go to Lists
                            NotificationCenter.default.post(name: .navigateToListsTab, object: nil)
                            horizontalOffset = 0
                            isDraggingHorizontally = false
                        } else {
                            // Reset with animation if threshold not met
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                horizontalOffset = 0
                            }
                            isDraggingHorizontally = false
                        }
                    }
            )
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.all, edges: .bottom)
        .task {
            await viewModel.loadClips()
        }
        .onDisappear {
            // Pause all clips when leaving the Clips tab
            NotificationCenter.default.post(name: .pauseAllClips, object: nil)
        }
        .onChange(of: scenePhase) { _ in
            // Pause all clips when app goes to background
            if scenePhase != .active {
                NotificationCenter.default.post(name: .pauseAllClips, object: nil)
            }
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            // Check quota when user scrolls to next clip
            checkQuotaLimit(for: newValue)
        }
        .onChange(of: appState.isAuthenticated) { oldValue, newValue in
            guard newValue, newValue != oldValue else { return }
            quotaManager.resetQuota()
            showAccountGate = false
            showDailyPaywall = false
        }
    }

    // MARK: - Quota Check

    private func checkQuotaLimit(for index: Int) {
        guard index > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000)
            quotaManager.recordClipWatched()

            guard quotaManager.hasReachedLimit else { return }

            if appState.isAuthenticated {
                if !showDailyPaywall {
                    showDailyPaywall = true
                }
            } else if !showAccountGate {
                showAccountGate = true
            }
        }
    }

    private var clipsScrollView: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                let screenHeight = UIScreen.main.bounds.height
                let screenWidth = geometry.size.width

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.clips.enumerated()), id: \.offset) { index, clip in
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
                            .frame(width: screenWidth, height: screenHeight)
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
                .scrollPosition(id: .init(get: {
                    return currentIndex
                }, set: { newValue in
                    if let newIndex = newValue {
                        currentIndex = newIndex
                    }
                }))
                .ignoresSafeArea(.all) // Ignore all safe areas for proper paging
                .onAppear {
                    proxy.scrollTo(0, anchor: .top)
                }
            }
        }
        .ignoresSafeArea(.all) // Full screen scroll view
    }

    private var loadingView: some View {
        GeometryReader { geometry in
            ZStack {
                // Skeleton clip cards (no background, just transparent skeletons)
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        SkeletonClipCard()
                            .frame(height: geometry.size.height / 3)
                    }
                }
                .ignoresSafeArea()
                
                // Center content overlay
                VStack(spacing: 24) {
                    // Animated icon
                    Image("stars90x90")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .opacity(0.95)
                        .scaleEffect(viewModel.isLoading ? 1.15 : 1.0)
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(
                            .easeInOut(duration: 2.0)
                            .repeatForever(autoreverses: false),
                            value: viewModel.isLoading
                        )
                    
                    VStack(spacing: 12) {
                        // Main message
                        Text("Crafting Your Perfect Feed")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        // Subtext
                        Text("We're handpicking the best clips just for you ✨")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        
                        // Animated dots
                        HStack(spacing: 8) {
                            ForEach(0..<3) { dot in
                                Circle()
                                    .fill(Color.theme.accentOrange)
                                    .frame(width: 10, height: 10)
                                    .scaleEffect(viewModel.isLoading ? 1.2 : 0.6)
                                    .opacity(viewModel.isLoading ? 1.0 : 0.5)
                                    .animation(
                                        .easeInOut(duration: 0.8)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(dot) * 0.25),
                                        value: viewModel.isLoading
                                    )
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .background(Color.black.ignoresSafeArea())
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

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Oops!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Text(error)
                .font(.system(size: 16))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task {
                    viewModel.errorMessage = nil
                    await viewModel.loadClips()
                }
            } label: {
                Text("Try Again")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(Color.orange)
                    .cornerRadius(25)
            }
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
    @State private var isFullyVisible = false
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
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        // Get safe area from window scene (more reliable when ignoring safe areas)
        let safeAreaTop = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
                
        ZStack(alignment: .bottomTrailing) {
            // Full-screen YouTube player (iframe offset by safe area internally)
            VerticalYouTubePlayer(
                clipId: clip.id,
                videoId: clip.videoId,
                shouldPlay: isCurrentClip && isFullyVisible,
                safeAreaTop: safeAreaTop
            )
            .frame(width: screenWidth, height: screenHeight)
            .background(Color.black)
            .clipped()
            .edgesIgnoringSafeArea(.all)
            .contentShape(Rectangle())
            .background(
                GeometryReader { innerGeometry in
                    Color.clear
                        .preference(key: ViewOffsetKey.self, value: innerGeometry.frame(in: .global).minY)
                }
            )
            .onPreferenceChange(ViewOffsetKey.self) { offset in
                // Check if clip is fully visible (within threshold)
                let threshold: CGFloat = 50 // Allow small offset
                let newIsFullyVisible = abs(offset) < threshold
                
                if newIsFullyVisible != isFullyVisible {
                    isFullyVisible = newIsFullyVisible
                    if isFullyVisible && isCurrentClip {
                        onBecomeVisible()
                    }
                }
            }
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
            .padding(.bottom, showControls ? 130 : 100)
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
            .padding(.bottom, showControls ? 130 : 100)
            .padding(.trailing, 80)
            .animation(.bouncy, value: showControls)
        }
        .onAppear {
            hasAppeared = true
            
            // Start tracking watch time
            watchStartTime = Date()
            engagementTracker.startWatchingClip(clip)
        }
        .onDisappear {
            hasAppeared = false
            isFullyVisible = false
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
    let safeAreaTop: CGFloat // Top safe area inset to offset YouTube controls
    
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
                * { margin: 0; padding: 0; box-sizing: border-box; -webkit-user-select: none; -webkit-touch-callout: none; }
                html, body { 
                    width: 100%; 
                    height: 100%; 
                    background: #000; 
                    overflow: hidden;
                    position: fixed;
                }
                #player-container { 
                    position: fixed; 
                    top: \(safeAreaTop)px; 
                    left: 0; 
                    width: 100%; 
                    height: calc(100% - \(safeAreaTop)px); 
                    background: #000;
                    overflow: hidden;
                }
                #player { 
                    position: absolute; 
                    top: 0; 
                    left: 0; 
                    width: 100%; 
                    height: 100%; 
                    border: none;
                    pointer-events: auto; 
                }
                iframe { 
                    position: absolute;
                    top: 0;
                    left: 0;
                    width: 100%;
                    height: 100%;
                    border: none;
                }
            </style>
        </head>
        <body>
            <div id="player-container"><div id="player"></div></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
                var player;
                function onYouTubeIframeAPIReady() {
                    player = new YT.Player('player', {
                        height: '100%', 
                        width: '100%', 
                        videoId: '\(videoId)',
                        playerVars: { 
                            'playsinline': 1, 
                            'autoplay': 1, 
                            'mute': 0, 
                            'loop': 1, 
                            'playlist': '\(videoId)', 
                            'controls': 1, 
                            'showinfo': 1, 
                            'rel': 0, 
                            'fs': 1, 
                            'modestbranding': 1, 
                            'iv_load_policy': 3, 
                            'cc_load_policy': 1, 
                            'enablejsapi': 1, 
                            'origin': window.location.origin 
                        },
                        events: { 
                            'onReady': function(e) { 
                                console.log('Player Ready');
                            }, 
                            'onStateChange': function(e) { 
                                if (e.data === YT.PlayerState.ENDED) player.playVideo(); 
                            } 
                        }
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
        
        Task {
            if isItemInList(list) {
                if let item = list.items.first(where: { $0.mediaId == itemId }) {
                    try? await listManager.removeFromList(listId: list.id, itemId: item.id)
                    dismiss()
                }
            } else {
                do {
                    if mediaType == .movie, let movieId = movieId {
                        let movieDetails = try await TMDBService.shared.getMovieDetails(id: movieId)
                        try? await listManager.addToList(listId: list.id, movie: movieDetails, mediaType: .movie)
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
                        try? await listManager.addToList(listId: list.id, movie: movie, mediaType: .tv)
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

// MARK: - Skeleton Loading Card
struct SkeletonClipCard: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background shimmer
            LinearGradient(
                colors: [
                    Color(white: 0.15),
                    Color(white: 0.2),
                    Color(white: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(isAnimating ? 0.6 : 0.3)
            
            // Shimmer effect overlay
            GeometryReader { geometry in
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.1),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geometry.size.width * 0.3)
                .offset(x: isAnimating ? geometry.size.width : -geometry.size.width * 0.3)
            }
            
            // Skeleton UI elements on the right (like real clips)
            HStack {
                Spacer()
                
                VStack(spacing: 24) {
                    Spacer()
                    
                    // Like button skeleton
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 48, height: 48)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 30, height: 12)
                    }
                    
                    // Comment button skeleton
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 48, height: 48)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 30, height: 12)
                    }
                    
                    // Add to list button skeleton
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 48, height: 48)
                    
                    // Share button skeleton
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 48, height: 48)
                    
                    Spacer()
                        .frame(height: 100) // Safe area spacing
                }
                .padding(.trailing, 12)
            }
            
            // Bottom title/description skeleton
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 200, height: 20)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 280, height: 14)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 150, height: 14)
            }
            .padding(.leading, 16)
            .padding(.bottom, 120) // Safe area spacing
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
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
    static let navigateToDiscoveryTab = Notification.Name("navigateToDiscoveryTab")
    static let navigateToClipsTab = Notification.Name("navigateToClipsTab")
    static let navigateToListsTab = Notification.Name("navigateToListsTab")
    static let dailyQuotaLimitReached = Notification.Name("dailyQuotaLimitReached")
}

// Preference key for tracking view offset
struct ViewOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ClipsView()
        .environmentObject(AppState())
}
