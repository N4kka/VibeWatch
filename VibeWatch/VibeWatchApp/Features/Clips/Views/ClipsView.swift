import SwiftUI
import AVKit
import YouTubeiOSPlayerHelper

struct ClipsView: View {
    @StateObject private var viewModel = ClipsViewModel()
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var showDailyPaywall = false
    @State private var showAccountGate = false
    @State private var navigateToDiscovery = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var hasScrolledToSavedPosition = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSearch = false

    var body: some View {
        // Main content - Clips
        ZStack {
            VStack(spacing: 0) {
                OfflineBanner()
                
                if viewModel.isLoading {
                    loadingView
                        .transition(.opacity)
                } else if let error = viewModel.error {
                    errorView(error)
                        .transition(.opacity)
                } else if viewModel.clips.isEmpty {
                    emptyStateView
                        .transition(.opacity)
                } else {
                    clipsScrollView
                        .transition(.opacity)
                }
            }
            .offset(x: dragOffset) // Apply drag offset
            // Horizontal swipe navigation (AI / Discovery) without blocking vertical scroll
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // Only allow horizontal drag if it dominates vertical
                        if abs(value.translation.width) > abs(value.translation.height) {
                            dragOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        let screenWidth = UIScreen.main.bounds.width
                        let threshold = screenWidth * 0.5
                        
                        if value.translation.width < -threshold {
                            // Swipe Left -> Go to AI (Tab 2)
                            NotificationCenter.default.post(name: .navigateToAITab, object: nil)
                            // Reset offset after a delay to allow transition
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                dragOffset = 0
                            }
                        } else if value.translation.width > threshold {
                            // Swipe Right -> Go to Discovery (Tab 0)
                            NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                dragOffset = 0
                            }
                        } else {
                            // Snap back
                            withAnimation(.spring()) {
                                dragOffset = 0
                            }
                        }
                    }
            )

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
                .environmentObject(quotaManager)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(101)
            }

            if showDailyPaywall {
                DailyLimitPaywallView(isPresented: $showDailyPaywall, onComeBack: {
                    NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
                })
                .environmentObject(quotaManager)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.all, edges: .bottom)
        .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.clips.isEmpty)
        .task {
            await handleViewAppearance()
        }
        .onDisappear {
            // Pause all clips when leaving the Clips tab
            NotificationCenter.default.post(name: .pauseAllClips, object: nil)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onChange(of: viewModel.currentIndex) { oldValue, newValue in
            // Check quota when user scrolls to next clip
            checkQuotaLimit(for: newValue)
        }
        .onChange(of: appState.isAuthenticated) { oldValue, newValue in
            guard newValue, newValue != oldValue else { return }
            quotaManager.resetQuota()
            showAccountGate = false
            showDailyPaywall = false
        }
        
        .overlay(alignment: .top) {
            searchBar
        }
        .background(searchNavigationLink)
    }

    // MARK: - Lifecycle Handlers
    private func handleViewAppearance() async {
        await viewModel.loadClips()
        AnalyticsService.shared.logScreenView(screenName: "Clips", screenClass: "ClipsView")
    }

    private func handleScenePhaseChange(from old: ScenePhase, to new: ScenePhase) {
        guard old != new else { return }
        
        switch (old, new) {
        case (_, .active):
            // Resumed from background/inactive, no specific action needed for now
            break
        case (.active, _):
            // Moved to background/inactive
            NotificationCenter.default.post(name: .pauseAllClips, object: nil)
        default:
            break
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

    private var searchBar: some View {
        let safeTop = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
        
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.7))
                
                Text("clips.search.placeholder".localized)
                    .foregroundColor(.white.opacity(0.7))
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture {
                showSearch = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, safeTop + 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.8),
                    Color.black.opacity(0.4),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }
    
    private var searchNavigationLink: some View {
        Color.clear
            .frame(height: 0)
            .navigationDestination(isPresented: $showSearch) {
                ClipsSearchView()
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
                                isCurrentClip: viewModel.currentIndex == index,
                                onBecomeVisible: {
                                    viewModel.currentIndex = index
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
                                if remainingClips <= AppConstants.Clips.paginationThreshold {
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
                    return viewModel.currentIndex
                }, set: { newValue in
                    if let newIndex = newValue {
                        viewModel.currentIndex = newIndex
                    }
                }))
                .ignoresSafeArea(.all) // Ignore all safe areas for proper paging
                .onAppear {
                    // Only scroll to saved position on first appearance
                    if !hasScrolledToSavedPosition {
                        proxy.scrollTo(viewModel.currentIndex, anchor: .top)
                        hasScrolledToSavedPosition = true
                    }
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
                        Text("clips.feed.craftingTitle".localized)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        // Subtext
                        Text("clips.feed.craftingSubtitle".localized)
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

    private func errorView(_ error: AppError) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(error.errorDescription ?? "Oops!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            if let recoverySuggestion = error.recoverySuggestion {
                Text(recoverySuggestion)
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                Task {
                    viewModel.error = nil
                    await viewModel.loadClips()
                }
            } label: {
                Text("common.tryAgain".localized)
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
    @State private var commentCount: Int
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
        _commentCount = State(initialValue: clip.comments)
    }
    
    var body: some View {
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        // Get safe area from window scene (more reliable when ignoring safe areas)
        let safeAreaTop = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
                
        ZStack(alignment: .bottomTrailing) {
            // Full-screen YouTube player using official YTPlayerView (offset by safe area internally)
            ZStack {
                VerticalYouTubePlayer(
                    clipId: clip.id,
                    videoId: clip.videoId,
                    shouldPlay: isCurrentClip && isFullyVisible,
                    safeAreaTop: safeAreaTop
                )
                
                // Edge gesture areas to ensure swipe works even over WebView
                HStack {
                    Color.clear
                        .frame(width: 20)
                        .contentShape(Rectangle())
                    Spacer()
                    Color.clear
                        .frame(width: 20)
                        .contentShape(Rectangle())
                }
            }
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
                    count: commentCount,
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
            CommentsView(clipId: clip.id) { newCount in
                commentCount = newCount
            }
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
        
        // Hide controls after 3 seconds - struct doesn't need weak self
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = false
                }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView(topInset: safeAreaTop)
        container.playerView.delegate = context.coordinator
        container.playerView.backgroundColor = .black
        container.playerView.isOpaque = false
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: PlayerContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.shouldPlay = shouldPlay
        container.topInset = safeAreaTop

        if context.coordinator.currentClipId != clipId {
            context.coordinator.currentClipId = clipId
            context.coordinator.isReady = false
            let playerVars: [String: Any] = [
                "playsinline": 1,
                "autoplay": shouldPlay ? 1 : 0,
                "controls": 1,
                "modestbranding": 1,
                "fs": 1,
                "rel": 0,
                "origin": "https://www.vibewatch.app"
            ]
            container.playerView.load(withVideoId: videoId, playerVars: playerVars)
        } else {
            if shouldPlay {
                if context.coordinator.isReady {
                    container.playerView.playVideo()
                }
            } else {
                container.playerView.pauseVideo()
            }
        }
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        uiView.playerView.stopVideo()
    }

    @MainActor
    class Coordinator: NSObject, @MainActor YTPlayerViewDelegate {
        var parent: VerticalYouTubePlayer
        var currentClipId: String?
        var isReady = false
        var shouldPlay = false

        init(_ parent: VerticalYouTubePlayer) {
            self.parent = parent
        }

        func playerViewDidBecomeReady(_ playerView: YTPlayerView) {
            isReady = true
            if shouldPlay {
                playerView.playVideo()
            }
        }

        func playerView(_ playerView: YTPlayerView, didChangeTo state: YTPlayerState) {
            if state == .ended {
                playerView.seek(toSeconds: 0, allowSeekAhead: true)
                if shouldPlay {
                    playerView.playVideo()
                }
            }
        }
    }
}

final class PlayerContainerView: UIView {
    let playerView = YTPlayerView()
    private var topConstraint: NSLayoutConstraint?

    var topInset: CGFloat {
        didSet { topConstraint?.constant = topInset }
    }

    init(topInset: CGFloat) {
        self.topInset = topInset
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .black
        addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = playerView.topAnchor.constraint(equalTo: topAnchor, constant: topInset)
        NSLayoutConstraint.activate([
            topConstraint!,
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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
    let onCountsChange: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Use our new CommentsListView
                CommentsListView(
                    clipId: clipId,
                    userId: appState.currentUser?.id ?? "guest",
                    onCountsChange: onCountsChange
                )
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .presentationCornerRadius(20)
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
                    CachedAsyncImage(url: url) { image in
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
                CachedAsyncImage(url: url) { image in
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
                    CachedAsyncImage(url: url) { image in
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
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ClipsView()
        .environmentObject(AppState())
}
