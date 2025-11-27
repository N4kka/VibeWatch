import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState // Injected from App
    @Environment(\.scenePhase) private var scenePhase // Monitor app lifecycle
    @State private var selectedTab = 0
    @State private var selectedMovie: Movie?
    @State private var selectedMediaType: MediaType = .movie
    @State private var isLoading = true
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    
    // MARK: - Custom Tab Bar View (iOS 17-25)
    private var customTabBarView: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    DiscoveryView(selectedMovie: $selectedMovie, selectedMediaType: $selectedMediaType)
                        .tag(0)
                    
                    ClipsView()
                        .tag(1)
                    
                    ListsView()
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                
                // Hide bottom bar when on Clips tab (swipe-only navigation)
                VStack(spacing: 0) {
                    Spacer()
                    
                    if selectedTab != 1 {
                        LiquidGlassBottomBar(selectedTab: $selectedTab)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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
                    .toolbar(selectedTab == 1 ? .hidden : .visible, for: .tabBar)
                
                ListsView()
                    .tabItem {
                        Label("tab.lists".localized, systemImage: "list.bullet")
                    }
                    .tag(2)
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
            if isLoading {
                SplashScreen()
                    .transition(.opacity)
                    .task {
                        // REAL WORK: Wait for the AppState to signal ready
                        // This replaces the fake timer
                        // We give it a minimum 1.5s just so the logo animation isn't jarring
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        
                        // Wait for actual preload if it's still running
                        while appState.isPreloading {
                            try? await Task.sleep(nanoseconds: 100_000_000) // Check every 0.1s
                        }
                        
                        withAnimation(.easeOut(duration: 0.5)) {
                            isLoading = false
                        }
                    }
            } else if showOnboarding {
                OnboardingView(showOnboarding: $showOnboarding)
                    .transition(.opacity)
                    .onChange(of: showOnboarding) { newValue in
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
                selectedTab = 2
            }
            print("📝 [MainTabView] Navigated to Lists tab")
        }
        .background(scenePhaseMonitor) // Monitor app lifecycle for subscription status
        .withErrorHandling()
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
                icon: "list.bullet",
                title: "tab.lists".localized,
                isSelected: selectedTab == 2
            ) {
                selectedTab = 2
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
                        await ClipQuotaService.shared.checkIsProUser()
                    }
                }
            }
    }
}
