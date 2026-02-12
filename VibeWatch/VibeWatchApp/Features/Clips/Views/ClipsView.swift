import SwiftUI
import AVKit
import YouTubeiOSPlayerHelper

@MainActor
struct ClipsView: View {
    @StateObject private var viewModel = ClipsViewModel()
    @StateObject private var gamificationService = GamificationService.shared
    @StateObject private var interstitialAdManager = InterstitialAdManager.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var showDailyPaywall = false
    @State private var showAccountGate = false
    @State private var navigateToDiscovery = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var hasScrolledToSavedPosition = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSearch = false
    @State private var isSearchTrayVisible = false
    @State private var inlineQuery = ""
    @State private var pendingSearchQuery: String?
    @FocusState private var isInlineSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAuroraAnimating = false
    @State private var isGlyphPulsing = false
    @State private var isProgressSweeping = false
    @State private var feedSessionId = UUID().uuidString
    @State private var seenClipIds: Set<String> = []

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
                }, source: "clips_quota")
                .environmentObject(quotaManager)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .background(Color.black.ignoresSafeArea())
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

            // Track clip for interstitial ads (free users only)
            if newValue > oldValue {
                interstitialAdManager.recordClipWatched(isProUser: quotaManager.isProUser)
            }
        }
        .onChange(of: appState.isAuthenticated) { oldValue, newValue in
            guard newValue, newValue != oldValue else { return }
            quotaManager.resetQuota()
            showAccountGate = false
            showDailyPaywall = false
        }
        
        .safeAreaInset(edge: .top) {
            searchDock
        }
        .overlay {
            searchDimOverlay
        }
        .overlay(alignment: .top) {
            searchTray
        }
        .background(searchNavigationLink)
        .xpToast(gamificationService: gamificationService)
        .onChange(of: isSearchTrayVisible) { _, newValue in
            if newValue {
                NotificationCenter.default.post(name: .pauseAllClips, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInlineSearchFocused = true
                }
            } else {
                isInlineSearchFocused = false
            }
        }
    }

    // MARK: - Lifecycle Handlers
    private func handleViewAppearance() async {
        feedSessionId = UUID().uuidString
        seenClipIds.removeAll()
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

    private var searchDock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("clips.title".localized)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("clips.search.placeholder".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()

                ProUpgradeIconButton(isProUser: quotaManager.isProUser, source: "clips_top_right")
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        isSearchTrayVisible = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        Text("clips.search.placeholder".localized)
                            .lineLimit(1)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            Color.black
                .ignoresSafeArea(edges: .top)
        )
    }

    private var searchTray: some View {
        Group {
            if isSearchTrayVisible {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white.opacity(0.85))
                        
                        TextField("clips.search.placeholder".localized, text: $inlineQuery)
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.none)
                            .focused($isInlineSearchFocused)
                            .onSubmit { launchSearch(with: inlineQuery) }
                        
                        if !inlineQuery.isEmpty {
                            Button {
                                inlineQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        
                        Button {
                            launchSearch(with: inlineQuery)
                        } label: {
                            Image(systemName: "arrow.forward.circle.fill")
                                .foregroundColor(.black)
                                .frame(width: 32, height: 32)
                                .background(Color.theme.accentOrange)
                                .clipShape(Circle())
                        }
                        
                        Button("common.cancel".localized) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                isSearchTrayVisible = false
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    
                    chipsRow
                }
                .padding(.horizontal, 16)
                .padding(.top, safeAreaTopInset + 10)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.95),
                            Color.black.opacity(0.82),
                            Color.black.opacity(0.6)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .top)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(50)
            }
        }
    }

    private var searchDimOverlay: some View {
        Group {
            if isSearchTrayVisible {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(30)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            isSearchTrayVisible = false
                        }
                    }
            }
        }
    }

    private var chipsRow: some View {
        let chips = [
            "clips.search.quotes".localized,
            "clips.search.characters".localized,
            "clips.search.scenes".localized,
            "clips.search.popular".localized
        ]

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        launchSearch(with: chip)
                    } label: {
                        Text(chip)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.14))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    private var safeAreaTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }
    
    private func launchSearch(with query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                isSearchTrayVisible = false
            }
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pendingSearchQuery = trimmed
        inlineQuery = trimmed
        showSearch = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            isSearchTrayVisible = false
        }
    }

    private var searchNavigationLink: some View {
        Color.clear
            .frame(height: 0)
            .navigationDestination(isPresented: $showSearch) {
                ClipsSearchView(initialQuery: pendingSearchQuery)
            }
    }

    private var clipsScrollView: some View {
        GeometryReader { outerGeometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.clips.enumerated()), id: \.offset) { index, clip in
                            GeometryReader { innerGeometry in
                                let context = AnalyticsContext(
                                    source: "clips_feed",
                                    position: index,
                                    sessionId: feedSessionId
                                )
                                ClipPlayerView(
                                    clip: clip,
                                    isCurrentClip: viewModel.currentIndex == index,
                                    onBecomeVisible: {
                                        viewModel.currentIndex = index
                                        if !seenClipIds.contains(clip.id) {
                                            seenClipIds.insert(clip.id)
                                            AnalyticsService.shared.logClipImpression(
                                                clip: clip,
                                                context: context
                                            )
                                        }
                                    },
                                    onLikeToggle: { isLiked in
                                        viewModel.toggleLike(for: clip.id, isLiked: isLiked)
                                    },
                                    analyticsContext: context
                                )
                            }
                            .frame(width: outerGeometry.size.width, height: outerGeometry.size.height)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    // Only scroll to saved position on first appearance
                    if !hasScrolledToSavedPosition {
                        proxy.scrollTo(viewModel.currentIndex, anchor: .top)
                        hasScrolledToSavedPosition = true
                    }
                }
            }
        }
    }

    private var loadingView: some View {
        GeometryReader { geometry in
            ZStack {
                // Animated aurora backdrop
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.53, blue: 0.28),
                            Color(red: 0.74, green: 0.27, blue: 0.93),
                            Color(red: 0.18, green: 0.33, blue: 0.78)
                        ],
                        startPoint: isAuroraAnimating ? .topLeading : .bottomTrailing,
                        endPoint: isAuroraAnimating ? .bottomTrailing : .topLeading
                    )
                    .opacity(0.55)
                    .blur(radius: 50)
                    
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.95),
                            Color.black.opacity(0.75),
                            Color.black.opacity(0.9)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true)) {
                        isAuroraAnimating = true
                    }
                }

                // Skeleton clip cards with shimmer
                VStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { index in
                        SkeletonClipCard()
                            .frame(height: geometry.size.height / 3.2)
                            .padding(.horizontal, 12)
                            .offset(y: reduceMotion ? 0 : CGFloat(index) * 6)
                    }
                }
                .ignoresSafeArea()
                
                // Center content overlay
                VStack(spacing: 18) {
                    // Animated icon badge
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 140, height: 140)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .scaleEffect(isGlyphPulsing ? 1.08 : 0.96)
                        
                        Image("stars90x90")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 88, height: 88)
                            .opacity(0.95)
                            .scaleEffect(isGlyphPulsing ? 1.12 : 0.98)
                            .rotationEffect(.degrees(isGlyphPulsing && !reduceMotion ? 360 : 0))
                    }
                    .animation(
                        reduceMotion ?
                            .none :
                            .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                        value: isGlyphPulsing
                    )
                    
                    VStack(spacing: 10) {
                        // Main message
                        Text("clips.feed.craftingTitle".localized)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        // Subtext
                        Text("clips.feed.craftingSubtitle".localized)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                        
                        // Breathing progress capsule
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 10)
                            .overlay(
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.theme.accentOrange.opacity(0.9),
                                                    Color.purple.opacity(0.85)
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: proxy.size.width * 0.35)
                                        .offset(x: isProgressSweeping ? proxy.size.width * 0.65 : 0)
                                        .animation(
                                            reduceMotion ?
                                                .none :
                                                .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                                            value: isProgressSweeping
                                        )
                                }
                            )
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
                .onAppear {
                    if !reduceMotion {
                        isGlyphPulsing = true
                        isProgressSweeping = true
                    }
                }
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

            Text(error.errorDescription ?? "error.oops".localized)
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
    let analyticsContext: AnalyticsContext?
    
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
    
    init(
        clip: Clip,
        isCurrentClip: Bool,
        onBecomeVisible: @escaping () -> Void,
        onLikeToggle: @escaping (Bool) -> Void,
        analyticsContext: AnalyticsContext? = nil
    ) {
        self.clip = clip
        self.isCurrentClip = isCurrentClip
        self.onBecomeVisible = onBecomeVisible
        self.onLikeToggle = onLikeToggle
        self.analyticsContext = analyticsContext
        _isLiked = State(initialValue: clip.isLiked)
        _likeCount = State(initialValue: clip.likes)
        _commentCount = State(initialValue: clip.comments)
    }
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // YouTube player contained within bounds
            ZStack {
                VerticalYouTubePlayer(
                    clipId: clip.id,
                    videoId: clip.videoId,
                    shouldPlay: isCurrentClip && isFullyVisible
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipped()
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
            
            // Action buttons on the right (always visible)
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
            .padding(.bottom, showControls ? 140 : 60)
            .animation(.easeInOut(duration: 0.2), value: showControls)

            // Title and description on the left bottom (always visible)
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
            .padding(.bottom, showControls ? 140 : 60)
            .padding(.trailing, 80)
            .animation(.easeInOut(duration: 0.2), value: showControls)
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
                let totalDuration = clip.duration > 0 ? TimeInterval(clip.duration) : 60
                engagementTracker.updateWatchTime(
                    clipId: clip.id,
                    duration: watchDuration,
                    totalDuration: totalDuration
                )
                engagementTracker.endWatchingClip(clipId: clip.id, genres: [], actors: [])
                AnalyticsService.shared.logClipCompletion(
                    clip: clip,
                    watchedSeconds: watchDuration,
                    context: analyticsContext
                )
                let completionRatio = AnalyticsContext.completionRatio(
                    watched: watchDuration,
                    total: totalDuration
                )
                Task {
                    await SupabaseService.shared.logClipSignal(
                        clipId: clip.id,
                        signalType: "completion",
                        signalValue: completionRatio,
                        context: analyticsContext
                    )

                    // Award gamification XP for clip completion
                    if let userId = await AuthService.shared.currentUser?.id {
                        let isPro = await ClipQuotaService.shared.checkIsProUser()
                        await GamificationService.shared.recordClipWatch(
                            userId: userId,
                            clipId: clip.id,
                            completionRate: completionRatio,
                            isPro: isPro
                        )
                    }
                }
            }
            
            watchStartTime = nil
            accumulatedWatchTime = 0
        }
        .sheet(isPresented: $showComments) {
            CommentsView(clipId: clip.id, analyticsContext: analyticsContext) { newCount in
                commentCount = newCount
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showAddToList) {
            AddToListView(
                clipId: clip.id,
                movieId: clip.movieId,
                tvShowId: clip.tvShowId, 
                mediaType: clip.movieId != nil ? .movie : .tv,
                analyticsContext: analyticsContext
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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView()
        container.playerView.delegate = context.coordinator
        container.playerView.backgroundColor = .black
        container.playerView.isOpaque = false
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: PlayerContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.shouldPlay = shouldPlay

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

    init() {
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

        // Simple edge-to-edge constraints
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
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
    let analyticsContext: AnalyticsContext?
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
                    analyticsContext: analyticsContext,
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
    let clipId: String?
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: MediaType
    let analyticsContext: AnalyticsContext?
    
    init(
        clipId: String? = nil,
        movieId: Int? = nil,
        tvShowId: Int? = nil,
        mediaType: MediaType = .movie,
        analyticsContext: AnalyticsContext? = nil
    ) {
        self.clipId = clipId
        self.movieId = movieId
        self.tvShowId = tvShowId
        self.mediaType = mediaType
        self.analyticsContext = analyticsContext
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
                        try? await listManager.addToList(
                            listId: list.id,
                            movie: movieDetails,
                            mediaType: .movie,
                            analyticsContext: analyticsContext
                        )
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
                        try? await listManager.addToList(
                            listId: list.id,
                            movie: movie,
                            mediaType: .tv,
                            analyticsContext: analyticsContext
                        )
                    }

                    if let clipId {
                        await SupabaseService.shared.logClipSignal(
                            clipId: clipId,
                            signalType: "add_to_list",
                            signalValue: 1,
                            context: analyticsContext
                        )
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            guard !reduceMotion else {
                isAnimating = false
                return
            }
            withAnimation(
                .easeInOut(duration: 1.6)
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
