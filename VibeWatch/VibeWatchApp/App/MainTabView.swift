import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState // Injected from App
    @EnvironmentObject var authService: AuthService
    @Environment(\.scenePhase) private var scenePhase // Monitor app lifecycle
    @State private var selectedTab = 0
    @State private var selectedMovie: Movie?
    @State private var selectedMediaType: MediaType = .movie
    @State private var isLoading = true
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var hasClearedAuthOnFreshInstall = false
    @StateObject private var aiViewModel = AIRecommendationViewModel()
    @State private var showProPaywall = false
    @State private var proPaywallSource = "unknown"
    
    private var passwordRecoveryBinding: Binding<Bool> {
        Binding(
            get: { authService.isPasswordRecoveryFlowPresented },
            set: { authService.isPasswordRecoveryFlowPresented = $0 }
        )
    }
    
    // MARK: - Custom Tab Bar View (iOS 17-25)
    private var customTabBarView: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Simple tab container - no swipe navigation
                ZStack {
                    if selectedTab == 0 {
                        DiscoveryView(selectedMovie: $selectedMovie, selectedMediaType: $selectedMediaType)
                            .transition(.opacity)
                    }
                    
                    if selectedTab == 1 {
                        ClipsView()
                            .transition(.opacity)
                    }
                    
                    if selectedTab == 2 {
                        AIRecommendationsView(viewModel: aiViewModel)
                            .transition(.opacity)
                    }
                    
                    if selectedTab == 3 {
                        ListsView()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: selectedTab)
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    LiquidGlassBottomBar(selectedTab: $selectedTab)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea(edges: .bottom)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedTab)
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedMovie) { movie in
                if selectedMediaType == .movie {
                    MovieDetailView(movieId: movie.id)
                } else {
                    TVShowDetailView(tvShowId: movie.id)
                }
            }
        }
        .transition(.opacity)
    }
    
    // MARK: - Native Tab Bar View (iOS 26+)
    @available(iOS 26.0, *)
    private var nativeTabBarView: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                DiscoveryView(selectedMovie: $selectedMovie, selectedMediaType: $selectedMediaType)
                    .tabItem {
                        Label("tab.discovery".localized, systemImage: "house.fill")
                    }
                    .tag(0)
                
                ClipsView()
                    .tabItem {
                        Label("tab.clips".localized, systemImage: "play.rectangle.fill")
                    }
                    .tag(1)
                
                AIRecommendationsView(viewModel: aiViewModel)
                    .tabItem {
                        Label("tab.ai".localized, systemImage: "sparkles")
                    }
                    .tag(2)
                
                ListsView()
                    .tabItem {
                        Label("tab.lists".localized, systemImage: "list.bullet")
                    }
                    .tag(3)
            }
            .tint(.theme.accentOrange)
            .background(Color.theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedMovie) { movie in
                if selectedMediaType == .movie {
                    MovieDetailView(movieId: movie.id)
                } else {
                    TVShowDetailView(tvShowId: movie.id)
                }
            }
            .onAppear {
                configureNativeTabBar()
            }
        }
        .transition(.opacity)
    }
    
    // Configure native iOS tab bar appearance (iOS 26+)
    private func configureNativeTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        
        // Use system blur material for native glass effect
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor(Color.theme.background.opacity(0.8))
        
        // Selected item color (orange accent)
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Color.theme.accentOrange)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(Color.theme.accentOrange)
        ]
        
        // Unselected item color (gray)
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Color.theme.textSecondary)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(Color.theme.textSecondary)
        ]
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        ZStack {
            // Force dismiss splash screen if password recovery is presented
            if isLoading && !authService.isPasswordRecoveryFlowPresented {
                SplashScreen()
                    .transition(.opacity)
                    .task {
                        // REAL WORK: Wait for the AppState to signal ready
                        try? await Task.sleep(nanoseconds: 1_500_000_000)

                        // Wait for actual preload if it's still running
                        while appState.isPreloading {
                            try? await Task.sleep(nanoseconds: 100_000_000) // Check every 0.1s
                        }

                        // Additionally wait for Discovery content to be ready to avoid showing empty loader
                        await waitForDiscoveryContentReady()

                        withAnimation(.easeOut(duration: 0.5)) {
                            isLoading = false
                        }
                    }
            } else if showOnboarding {
                OnboardingContainerView(showOnboarding: $showOnboarding)
                    .transition(.opacity)
                    .onChange(of: showOnboarding) {_, newValue in
                        print("🔵 [MainTabView] showOnboarding changed to: \(newValue)")
                        if !newValue {
                            print("🔵 [MainTabView] Onboarding completed, showing main app")
                        }
                    }
            } else {
                // Use native tab bar for iOS 26+ (future), custom for iOS 17-25
                if #available(iOS 26.0, *) {
                    nativeTabBarView
                } else {
                    customTabBarView
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDiscoveryTab)) { _ in
            // Navigate to Discovery tab
            withAnimation {
                selectedTab = 0
            }
            print("🏠 [MainTabView] Navigated to Discovery tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToClipsTab)) { _ in
            // Navigate to Clips tab
            withAnimation {
                selectedTab = 1
            }
            print("🎬 [MainTabView] Navigated to Clips tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToListsTab)) { _ in
            // Navigate to Lists tab
            withAnimation {
                selectedTab = 3
            }
            print("📝 [MainTabView] Navigated to Lists tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAITab)) { _ in
            // Navigate to AI tab
            withAnimation {
                selectedTab = 2
            }
            print("🤖 [MainTabView] Navigated to AI tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentProPaywall)) { notification in
            let source = (notification.userInfo?["source"] as? String) ?? "unknown"
            proPaywallSource = source
            showProPaywall = true
        }
        .background(scenePhaseMonitor) // Monitor app lifecycle for subscription status
        .withErrorHandling()
        .task {
            ReviewPromptManager.shared.registerAppLaunch()
            
            // On first launch, clear any persisted auth from keychain
            if !hasClearedAuthOnFreshInstall && !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                print("🆕 [MainTabView] Fresh install detected - clearing keychain auth")
                hasClearedAuthOnFreshInstall = true
                
                // Mark as launched so we don't clear again on next launch
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                
                // Clear any persisted auth session from keychain
                do {
                    try await AuthService.shared.signOut(force: true)
                    print("✅ [MainTabView] Keychain auth cleared for fresh install")
                } catch {
                    print("⚠️ [MainTabView] Could not clear auth on fresh install: \(error)")
                }
                
                // Ensure app state reflects no auth
                await appState.checkAuthState()
            }
            
            // Request ATT permission (only relevant for ad attribution; not required for product analytics)
            await TrackingPermissionManager.shared.requestTrackingIfNeeded()
        }
        .fullScreenCover(isPresented: $showProPaywall) {
            ProPaywallView(isPresented: $showProPaywall, source: proPaywallSource)
                .environmentObject(appState)
                .environmentObject(authService)
                .environmentObject(DailyQuotaManager.shared)
        }
        .sheet(isPresented: passwordRecoveryBinding) {
            PasswordResetView(mode: .recovery, isPresented: passwordRecoveryBinding)
                .environmentObject(authService)
                .environmentObject(appState)
        }
    }

    /// Wait for Discovery content to be ready before dismissing splash screen
    /// This prevents showing an empty DiscoveryPage with a loader
    private func waitForDiscoveryContentReady() async {
        // Check if we have cached discovery content
        let hasCachedMovies = ContentCacheManager.shared.getCachedDiscoveryMovies() != nil
        let hasCachedTVShows = ContentCacheManager.shared.getCachedDiscoveryTVShows() != nil

        if hasCachedMovies || hasCachedTVShows {
            // We have cached content, no need to wait
            return
        }

        // No cached content, wait for Discovery content to be fetched
        // Maximum wait time: 3 seconds to avoid infinite splash
        let maxWaitTime: TimeInterval = 3.0
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if Discovery content is now available
            let hasMovies = ContentCacheManager.shared.getCachedDiscoveryMovies() != nil
            let hasTVShows = ContentCacheManager.shared.getCachedDiscoveryTVShows() != nil

            if hasMovies || hasTVShows {
                // Content is ready, exit
                return
            }

            // Wait 100ms before checking again
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Timeout reached, proceed anyway to avoid infinite splash
        print("⚠️ [MainTabView] Discovery content not ready after timeout, showing UI anyway")
    }
}

// MARK: - Custom Liquid Glass Bottom Bar Components

struct LiquidGlassBottomBar: View {
    @Binding var selectedTab: Int
    
    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(
                icon: "house.fill",
                title: "tab.discovery".localized,
                isSelected: selectedTab == 0
            ) {
                selectedTab = 0
            }
            
            TabBarButton(
                icon: "play.rectangle.fill",
                title: "tab.clips".localized,
                isSelected: selectedTab == 1
            ) {
                selectedTab = 1
            }
            
            TabBarButton(
                icon: "sparkles",
                title: "AI",
                isSelected: selectedTab == 2
            ) {
                selectedTab = 2
            }
            
            TabBarButton(
                icon: "list.bullet",
                title: "tab.lists".localized,
                isSelected: selectedTab == 3
            ) {
                selectedTab = 3
            }
        }
        .frame(height: 70)
        .padding(.horizontal, 4)
        .liquidGlass(cornerRadius: 35, opacity: 0.95)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        .shadow(color: Color.white.opacity(0.1), radius: 1, x: 0, y: -1)
    }
}

struct TabBarButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: isSelected ? .semibold : .regular))
                    .symbolEffect(.bounce, value: isSelected)
                
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSelected ?
                LinearGradient(
                    colors: [Color.theme.accentOrange, Color.theme.accentOrange.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                ) :
                LinearGradient(
                    colors: [Color.theme.textSecondary, Color.theme.textSecondary],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabButtonStyle())
    }
}

struct TabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Scene Phase Monitoring Extension
extension MainTabView {
    /// Monitor app lifecycle to check subscription status when app becomes active
    var scenePhaseMonitor: some View {
        Color.clear
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active && oldPhase != .active {
                    print("🔍 [App] App became active - checking subscription status")
                    Task {
                        AnalyticsService.shared.trackAppOpen()
                        DailyQuotaManager.shared.refreshForNewDayIfNeeded()
                        await ClipQuotaService.shared.checkIsProUser()
                    }
                }

                if newPhase == .background || newPhase == .inactive {
                    Task {
                        do {
                            try await PostHogClient.shared.flush()
                        } catch {
                            Logger.error("[MainTabView] Failed to flush PostHog events: \(error.localizedDescription)")
                        }
                    }
                }
            }
    }
}
