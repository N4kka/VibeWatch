import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState // Injected from App
    @EnvironmentObject var authService: AuthService
    @Environment(\.scenePhase) private var scenePhase // Monitor app lifecycle
    @ObservedObject private var navigationManager = AppNavigationManager.shared
    @State private var selectedTab = 0
    @State private var selectedMovie: Movie?
    @State private var selectedMediaType: MediaType = .movie
    @State private var isLoading = true
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var hasClearedAuthOnFreshInstall = false
    @StateObject private var aiViewModel = AIRecommendationViewModel()
    @State private var showProPaywall = false
    @State private var proPaywallSource = "unknown"
    /// §9.1 `DECISO`: l'AI esce dai tab e diventa un pulsante flottante persistente. Il tab che
    /// libera va al Tracking, che e' la schermata che un utente TV Time apre ogni giorno e che
    /// la spec vuole "a un tap".
    @State private var showAI = false
    /// Redesign 2.0: Scopri e Clip sono la stessa area (tab 0) con uno switcher. La modalità
    /// vive qui perché `.navigateToClipsTab` — deep link, quota, scorciatoie — deve poterla
    /// impostare anche quando l'utente sta su un altro tab.
    @State private var discoverMode: DiscoverMode = .discover

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
                        DiscoverHubView(
                            selectedMovie: $selectedMovie,
                            selectedMediaType: $selectedMediaType,
                            mode: $discoverMode
                        )
                        .transition(.opacity)
                    }

                    if selectedTab == 1 {
                        TVShowsTrackingView()
                            .transition(.opacity)
                    }

                    if selectedTab == 2 {
                        SocialView()
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

                    // Il FAB sta sopra la barra e non dentro: e' persistente, quindi non deve
                    // spostarsi ne' cambiare stato quando si cambia tab (§9.1).
                    HStack {
                        Spacer()
                        AIFloatingButton { showAI = true }
                            .padding(.trailing, 22)
                            .padding(.bottom, 12)
                    }

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
                // Il tipo lo porta l'item: la closure cattura una copia della view, e uno
                // selectedMediaType letto qui poteva essere stantio — con l'id di una serie
                // si apriva il film che per caso ha lo stesso id TMDB.
                if (movie.navigationMediaType ?? selectedMediaType) == .movie {
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
                DiscoverHubView(
                    selectedMovie: $selectedMovie,
                    selectedMediaType: $selectedMediaType,
                    mode: $discoverMode
                )
                .tabItem {
                    Label("tab.discovery".localized, systemImage: "house.fill")
                }
                .tag(0)

                TVShowsTrackingView()
                    .tabItem {
                        Label("tab.tracking".localized, systemImage: "tv")
                    }
                    .tag(1)

                SocialView()
                    .tabItem {
                        Label("tab.social".localized, systemImage: "person.2.fill")
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
                // Il tipo lo porta l'item: la closure cattura una copia della view, e uno
                // selectedMediaType letto qui poteva essere stantio — con l'id di una serie
                // si apriva il film che per caso ha lo stesso id TMDB.
                if (movie.navigationMediaType ?? selectedMediaType) == .movie {
                    MovieDetailView(movieId: movie.id)
                } else {
                    TVShowDetailView(tvShowId: movie.id)
                }
            }
            .onAppear {
                configureNativeTabBar()
            }
            .overlay(alignment: .bottomTrailing) {
                AIFloatingButton { showAI = true }
                    .padding(.trailing, 22)
                    .padding(.bottom, 56)
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
                        // If still preloading, poll until done (no-op when cache was instant)
                        while appState.isPreloading {
                            try? await Task.sleep(nanoseconds: 100_000_000) // Poll every 0.1s
                        }

                        // Wait for Discovery content only if we don't have cache yet
                        await waitForDiscoveryContentReady()

                        withAnimation(.easeOut(duration: 0.5)) {
                            isLoading = false
                        }
                    }
            } else if showOnboarding {
                OnboardingContainerView(showOnboarding: $showOnboarding)
                    .transition(.opacity)
                    .onChange(of: showOnboarding) {_, newValue in
                        Logger.debug("[MainTabView] showOnboarding changed to: \(newValue)")
                        if !newValue {
                            Logger.debug("[MainTabView] Onboarding completed, showing main app")
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
            // Redesign 2.0: Scopri e Clip condividono il tab 0 — "vai a Scopri" implica anche
            // la modalità, altrimenti chi arriva dal feed clip resterebbe sui clip.
            withAnimation {
                selectedTab = 0
                discoverMode = .discover
            }
            Logger.debug("[MainTabView] Navigated to Discovery tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToClipsTab)) { _ in
            // I Clip non sono più un tab: la stessa notifica ora porta al tab 0 in modalità
            // clip. Il nome resta per non rompere i chiamanti (deep link, quota, scorciatoie).
            withAnimation {
                selectedTab = 0
                discoverMode = .clips
            }
            Logger.debug("[MainTabView] Navigated to Clips mode")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToListsTab)) { _ in
            // Navigate to Lists tab
            withAnimation {
                selectedTab = 3
            }
            Logger.debug("[MainTabView] Navigated to Lists tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAITab)) { _ in
            // L'AI non e' piu' un tab (§9.1): la stessa notifica ora apre il pannello. Il nome
            // resta quello per non rompere i chiamanti, che sono deep link e scorciatoie.
            showAI = true
            Logger.debug("[MainTabView] Opened AI panel")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTrackingTab)) { _ in
            withAnimation { selectedTab = 1 }
            Logger.debug("[MainTabView] Navigated to Tracking tab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSocialTab)) { _ in
            withAnimation { selectedTab = 2 }
            Logger.debug("[MainTabView] Navigated to Social tab")
        }
        // `sheet` e non `fullScreenCover`: il primo si chiude con lo swipe verso il basso, il
        // secondo non si chiude affatto se dentro non c'e' un pulsante — ed e' com'era, un
        // pannello senza uscita. Il pulsante c'e' lo stesso, perche' lo swipe non si vede.
        .sheet(isPresented: $showAI) {
            // Il pulsante di chiusura ora vive nell'header interno della pagina (AIChatHeader),
            // quindi niente NavigationStack/toolbar: la pagina e' autosufficiente.
            AIRecommendationsView(viewModel: aiViewModel)
        }
        // SPEC v3 §9.4: `/@{username}` presenta il profilo come sheet, da qualunque tab. La
        // destinazione è la stessa schermata della ricerca; qui serve il suo NavigationStack
        // (per il titolo) e una porta esplicita — lo swipe non si vede (lezione del diario).
        .sheet(item: $navigationManager.profileLinkTarget) { target in
            NavigationStack {
                PublicProfileView(username: target.username)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { navigationManager.clearProfileLinkTarget() } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .accessibilityLabel(Text("common.close".localized))
                        }
                    }
            }
        }
        // Social feed M3: la push di like/commento apre la card di cui parla, non un tab generico.
        // Stessa forma del profilo qui sopra — sheet con NavigationStack proprio e porta esplicita.
        .sheet(item: $navigationManager.activityLinkTarget) { target in
            ActivityCardDetailView(
                activityId: target.activityId,
                onClose: { navigationManager.clearActivityLinkTarget() })
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentProPaywall)) { notification in
            let source = (notification.userInfo?["source"] as? String) ?? "unknown"
            proPaywallSource = source
            showProPaywall = true
        }
        .onChange(of: navigationManager.deepLinkTarget) { _, target in
            guard let target = target else { return }
            handleDeepLinkTarget(target)
        }
        .onAppear {
            // Handle cold-launch case: deepLinkTarget may be set before view appears
            if let target = navigationManager.deepLinkTarget {
                handleDeepLinkTarget(target)
            }
        }
        .background(scenePhaseMonitor) // Monitor app lifecycle for subscription status
        .withErrorHandling()
        .task {
            ReviewPromptManager.shared.registerAppLaunch()

            // On first launch, clear any persisted auth from keychain
            if !hasClearedAuthOnFreshInstall && !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                Logger.info("[MainTabView] Fresh install detected - clearing keychain auth")
                hasClearedAuthOnFreshInstall = true

                // Mark as launched so we don't clear again on next launch
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

                // Clear any persisted auth session from keychain
                do {
                    try await AuthService.shared.signOut(force: true)
                    Logger.info("[MainTabView] Keychain auth cleared for fresh install")
                } catch {
                    Logger.warning("[MainTabView] Could not clear auth on fresh install: \(error)")
                }

                // Ensure app state reflects no auth
                await appState.checkAuthState()
            }

            // Request ATT permission (only relevant for ad attribution; not required for product analytics)
            await TrackingPermissionManager.shared.requestTrackingIfNeeded()

            // Redesign 2.0 import: al lancio si ritrova l'import in corso (o l'ultimo
            // concluso con titoli da verificare) — il banner in Scopri vive di questo.
            ImportStatusCenter.shared.startIfNeeded()
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

    /// Navigate to the correct tab and detail view for a deep link target.
    /// Called from both .onChange(of: deepLinkTarget) and .onAppear for cold-launch support.
    private func handleDeepLinkTarget(_ target: DeepLinkTarget) {
        // Navigate to Discovery tab (tab 0) which hosts both MovieDetailView and TVShowDetailView
        withAnimation {
            selectedTab = 0
        }

        // Build a minimal Movie placeholder — navigationDestination(item: $selectedMovie) only
        // uses movie.id to route to MovieDetailView(movieId:) or TVShowDetailView(tvShowId:)
        var placeholder = Movie(
            id: target.mediaId,
            title: "",
            overview: "",
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            voteAverage: 0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )

        selectedMediaType = target.mediaType == "tv" ? .tv : .movie
        placeholder.navigationMediaType = selectedMediaType
        selectedMovie = placeholder
        navigationManager.clearDeepLinkTarget()
    }

    /// Wait for Discovery content to be ready before dismissing splash screen
    /// This prevents showing an empty DiscoveryPage with a loader.
    ///
    /// Returns as soon as the personalized carousels are cached — either already
    /// present, or hydrated by the background pre-warm during the wait — capped at
    /// 3s to avoid an infinite splash on a cold first install.
    private func waitForDiscoveryContentReady() async {
        let ready = await ReadinessWaiter.waitUntilReady(maxWait: 3.0) {
            SQLiteService.shared.hasCachedPersonalizedContent()
        }

        if !ready {
            Logger.warning("[MainTabView] Discovery content not ready after timeout, showing UI anyway")
        }
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
                icon: "tv",
                title: "tab.tracking".localized,
                isSelected: selectedTab == 1
            ) {
                selectedTab = 1
            }

            TabBarButton(
                icon: "person.2.fill",
                title: "tab.social".localized,
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
                    Logger.debug("[App] App became active - checking subscription status")
                    Task {
                        AnalyticsService.shared.trackAppOpen()
                        DailyQuotaManager.shared.refreshForNewDayIfNeeded()
                        await ClipQuotaService.shared.checkIsProUser()
                    }
                }

                // Niente flush manuale su background: l'SDK PostHog persiste la coda su disco
                // e gestisce da sé il flush (flushAt/flushInterval + lifecycle).
            }
    }
}
