import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @StateObject private var notificationService = NotificationService.shared
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var dailyQuotaManager = DailyQuotaManager.shared
    /// Redesign 2.0: la card livello nel profilo legge lo stesso stato del resto dell'app.
    @StateObject private var gamificationService = GamificationService.shared
    /// Redesign 2.0: le 4 tiles sono numeri del SERVER (`get_my_stats`), mai somme locali —
    /// la ragione della decisione "un posto solo" del 2026-08-01 resta rispettata: la fonte è
    /// una, questa è solo una seconda finestra sugli stessi numeri.
    @StateObject private var serverStats = ProfileStatsViewModel()
    @State private var showAnalyticsDashboard = false
    @State private var showBadges = false
    /// Redesign 2.0: la tile "Library" è una metrica di backlog, locale per natura (ARCH-001).
    /// Si mostra solo se le statistiche locali sono già state generate: qui non si lancia il
    /// ricalcolo intero della dashboard per una tile.
    @StateObject private var analyticsService = AnalyticsInsightsService.shared
    /// @username e follower/seguiti nell'header (prototipo 2.0). Lo username sta sul server;
    /// i conteggi arrivano da `get_public_profile` sul proprio profilo. Assenti finché non
    /// caricati: niente zeri con la faccia di un dato.
    @State private var ownUsername: String?
    @State private var profileBio: String?
    @State private var isProfilePublic = true
    @State private var socialCounts: (followers: Int, following: Int)?
    @State private var showEditProfile = false
    @State private var showNotificationPrefs = false
    @State private var showLanguageSelector = false
    @State private var showCacheSettings = false
    @State private var showPrivacyTerms = false
    @State private var showSignUp = false
    @State private var showSignIn = false
    @State private var showNotificationAlert = false
    @State private var showDisableConfirmation = false
    @State private var showLogoutConfirmation = false
    @State private var showPlatformSelector = false
    @State private var showUserSearch = false
    @State private var showDiary = false
    @State private var showImport = false
    /// SPEC v3 §9.4: il link pubblico del proprio profilo. Lo username sta sul server (lo
    /// specchio locale di `profiles` non lo ha), quindi la riga ha stati distinti: un errore
    /// di rete non deve presentarsi come "la riga non c'è".
    @State private var shareProfile: ShareProfileState = .loading

    enum ShareProfileState {
        case loading
        case ready(URL)
        /// I profili del backfill rimasti senza username (§3.7): niente pagina pubblica,
        /// niente link da condividere. Vuoto vero, non errore.
        case noUsername
        case failed
    }
    /// Social feed M1 — la card immagine del profilo (avatar + preferiti), da affiancare al
    /// link testuale di §9.4. Item-based: si presenta solo quando poster e avatar sono pronti.
    @State private var profileShareCard: ProfileShareCardItem?
    @State private var isPreparingShareCard = false

    struct ProfileShareCardItem: Identifiable {
        let id = UUID()
        let content: ShareCardContent
    }
    @State private var showChangePassword = false
    @State private var showHelpSupport = false
    @State private var showFeedback = false
    @State private var selectedFeedbackType: FeedbackType?
    @State private var showUpgradePaywall = false
    @State private var selectedFavorite: ProfileFavoritesViewModel.Entry?
    @State private var pendingNotificationToggle = false
    @AppStorage("selectedPlatforms") private var selectedPlatformsData: Data = Data()
    @AppStorage("selectedProviderNames") private var selectedProviderNamesData: Data = Data()
    
    private var selectedPlatforms: Set<StreamingPlatform> {
        PlatformSelectionCodec.decode(selectedPlatformsData)
    }

    private var displayNameOrEmail: String {
        guard let user = appState.currentUser else { return "User" }

        // Show display name if it exists and is not empty
        if let displayName = user.displayName, !displayName.isEmpty {
            return displayName
        }

        // Otherwise show email
        return user.email
    }

    private var shouldShowEmailSubtitle: Bool {
        guard let user = appState.currentUser else { return false }

        // Show email as subtitle only if we're showing displayName as main text
        return user.displayName != nil && !(user.displayName?.isEmpty ?? true)
    }
    
    // MARK: - Condividi profilo (§9.4)

    /// Acceso dal 2026-08-02: vibewatchapp.com serve l'AASA (apex e www) e risponde alle due
    /// rotte con pagine vere, quindi il link condiviso ha una destinazione anche senza app.
    /// Il ramo "Coming soon" resta come interruttore di emergenza: se il sito cadesse a lungo,
    /// rimettere `false` spegne la riga senza toccare gli stati.
    private static let shareProfileEnabled = true

    /// La riga e il suo Divider insieme: nel caso `noUsername` spariscono entrambi, e la lista
    /// resta ben formata.
    @ViewBuilder
    private var shareProfileRow: some View {
        if !Self.shareProfileEnabled {
            // Non è un Button: un tap che non fa niente su una riga che sembra attiva è
            // l'invito a ripremere (la famiglia di difetti del pulsante Segui su se stessi).
            shareProfileLabel {
                Text("profile.share.comingSoon".localized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .opacity(0.55)
            Divider()
                .background(Color.white.opacity(0.1))
        } else {
            enabledShareProfileRow
        }
    }

    @ViewBuilder
    private var enabledShareProfileRow: some View {
        switch shareProfile {
        case .ready(let url):
            ShareLink(item: url) {
                shareProfileLabel { EmptyView() }
            }
            Divider()
                .background(Color.white.opacity(0.1))
        case .loading:
            shareProfileLabel {
                ProgressView().controlSize(.small)
            }
            .opacity(0.5)
            Divider()
                .background(Color.white.opacity(0.1))
        case .failed:
            // Il tap riprova: la freccia dice che qualcosa non è andato, senza rubare
            // alla riga il suo mestiere.
            Button {
                Task { await loadShareUsername() }
            } label: {
                shareProfileLabel {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            Divider()
                .background(Color.white.opacity(0.1))
        case .noUsername:
            EmptyView()
        }
    }

    /// La stessa forma di `SettingsRow`, che però è un Button chiuso: qui il contenitore
    /// cambia per stato (ShareLink, Button, niente).
    private func shareProfileLabel<Trailing: View>(
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 20))
                .foregroundColor(.theme.accentOrange)
                .frame(width: 30)

            Text("profile.share".localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textPrimary)

            Spacer()

            trailing()
        }
        .padding()
    }

    /// La riga "Condividi la card del profilo": prepara i materiali (avatar, poster dei
    /// preferiti) e poi apre `ShareCardSheet` con la card profilo già componibile.
    private var shareProfileCardRow: some View {
        SettingsRow(icon: "person.crop.rectangle",
                    title: "profile.shareCard".localized,
                    subtitle: "profile.shareCard.subtitle".localized,
                    value: isPreparingShareCard ? "…" : nil) {
            presentProfileShareCard()
        }
        .disabled(isPreparingShareCard)
    }

    private func presentProfileShareCard() {
        guard !isPreparingShareCard, let username = ownUsername else { return }
        isPreparingShareCard = true
        Task {
            // Stessa fonte della vetrina del profilo (`user_favorites` via il suo ViewModel):
            // la card mostra ESATTAMENTE ciò che la sezione preferiti mostra, non una copia.
            let favoritesVM = ProfileFavoritesViewModel()
            await favoritesVM.load()

            var movies: [ProfileShareCard.FavoriteItem] = []
            var shows: [ProfileShareCard.FavoriteItem] = []
            for entry in favoritesVM.entries {
                let item = await shareFavoriteItem(entry)
                if entry.mediaType == "movie" { movies.append(item) } else { shows.append(item) }
            }

            let avatar = await ShareCardRenderer.remoteImage(urlString: appState.currentUser?.avatarURL)

            profileShareCard = ProfileShareCardItem(content: .profile(.init(
                displayName: displayNameOrEmail,
                username: username,
                avatar: avatar,
                favoriteMovies: Array(movies.prefix(4)),
                favoriteShows: Array(shows.prefix(4)),
                // I follower sono già in memoria se l'header li ha caricati; niente fetch
                // apposta per un numero secondario della card.
                followerCount: socialCounts?.followers
            )))
            isPreparingShareCard = false
        }
    }

    private func shareFavoriteItem(_ entry: ProfileFavoritesViewModel.Entry) async -> ProfileShareCard.FavoriteItem {
        // Poster con la stessa scala di costi delle tile della vetrina (cache → specchio →
        // rete), poi l'immagine vera per la rasterizzazione.
        let path = await FavoritePosterResolver.live.posterPath(
            mediaType: entry.mediaType, tmdbId: entry.tmdbId)
        let poster = await ShareCardRenderer.posterImage(path: path, width: 342)
        let title = await shareFavoriteTitle(entry)
        return .init(title: title, poster: poster)
    }

    /// Il titolo serve alla card solo come segnaposto quando il poster manca: si cerca dove
    /// costa meno (cache dei dettagli, poi lo specchio delle liste) e ci si accontenta.
    private func shareFavoriteTitle(_ entry: ProfileFavoritesViewModel.Entry) async -> String {
        if entry.mediaType == "movie" {
            if let cached = (try? await DetailCacheService.shared.getCachedMovieDetails(movieId: entry.tmdbId)) ?? nil {
                return cached.movie.title
            }
        } else {
            if let cached = (try? await DetailCacheService.shared.getCachedTVShowDetails(tvShowId: entry.tmdbId)) ?? nil {
                return cached.tvShow.name
            }
        }

        let rows = (try? await SQLiteService.shared.queryRaw(
            """
            SELECT title FROM list_items
             WHERE media_id = ? AND media_type = ? AND deleted_at IS NULL
               AND title IS NOT NULL AND title <> ''
             LIMIT 1
            """,
            parameters: [entry.tmdbId, entry.mediaType]
        )) ?? []
        return (rows.first?["title"] as? String) ?? ""
    }

    private func loadShareUsername() async {
        if case .ready = shareProfile { return }
        shareProfile = .loading
        do {
            let state = try await SupabaseService.shared.usernameState()
            if let username = state?.username, !username.isEmpty {
                ownUsername = username
                shareProfile = .ready(UniversalLinks.profileURL(username: username))
            } else {
                shareProfile = .noUsername
            }
        } catch {
            // Un errore non è "non hai uno username" (§3.7 ha lasciato 19 profili senza):
            // i due casi hanno due rese diverse apposta.
            shareProfile = .failed
        }
    }

    /// Carica i dati del proprietario dalla tabella privata: la bio deve vedersi anche quando il
    /// profilo pubblico è spento, mentre la view pubblica correttamente non restituisce nulla.
    @MainActor
    private func loadOwnProfileDetails() async {
        do {
            guard let details = try await SupabaseService.shared.ownProfileDetails() else { return }
            ownUsername = details.username
            profileBio = details.bio
            isProfilePublic = details.isProfilePublic

            guard Self.shareProfileEnabled else { return }
            if let username = details.username, !username.isEmpty {
                shareProfile = .ready(UniversalLinks.profileURL(username: username))
            } else {
                shareProfile = .noUsername
            }
        } catch {
            if Self.shareProfileEnabled { shareProfile = .failed }
        }
    }

    /// I conteggi sono informazione secondaria dell'header: se la lettura fallisce la riga
    /// semplicemente non compare — un "0 Follower" inventato sarebbe peggio dell'assenza.
    @MainActor
    private func loadSocialCounts() async {
        guard let username = ownUsername else { return }
        if let detail = try? await SupabaseService.shared.publicProfile(username: username) {
            socialCounts = (detail.followers, detail.following)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                if appState.isAuthenticated {
                    authenticatedView
                } else {
                    unauthenticatedView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if appState.isAuthenticated {
                        Button("common.edit".localized) { showEditProfile = true }
                            .fontWeight(.semibold)
                            .foregroundColor(.theme.accentOrange)
                    }
                }
            }
            .task {
                guard appState.isAuthenticated else { return }
                // Identità privata e statistiche partono insieme. I contatori social aspettano
                // soltanto lo username, che è il loro input effettivo.
                async let profile: Void = loadOwnProfileDetails()
                async let stats: Void = serverStats.load()
                if let userId = appState.currentUser?.id {
                    await gamificationService.loadUserState(userId: userId)
                }
                _ = await (profile, stats)
                await loadSocialCounts()
            }
            .sheet(isPresented: $showLogoutConfirmation) {
                VWConfirmationSheet(
                    title: "profile.logoutConfirmationTitle".localized,
                    confirmTitle: "common.confirm".localized,
                    isDestructive: true,
                    onConfirm: {
                        showLogoutConfirmation = false
                        Task {
                            await handleLogout()
                        }
                    },
                    onCancel: {
                        showLogoutConfirmation = false
                    }
                )
                .vwModalPresentation()
            }
        }
        .onAppear {
            if appState.shouldShowSignIn {
                Logger.info("[ProfileView] Auto-opening Sign In sheet")
                showSignIn = true
                // Reset flag
                appState.shouldShowSignIn = false
            }
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showChangePassword) {
            PasswordResetView(mode: .change, isPresented: $showChangePassword)
                .environmentObject(authService)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .fullScreenCover(isPresented: $showPlatformSelector) {
            PlatformSelectionView()
        }
        .sheet(isPresented: $showEditProfile) {
            if let user = appState.currentUser {
                EditProfileView(
                    user: user,
                    username: ownUsername,
                    bio: profileBio,
                    isProfilePublic: isProfilePublic
                ) { username, bio, isPublic in
                    ownUsername = username
                    profileBio = bio
                    isProfilePublic = isPublic
                    Task { await loadSocialCounts() }
                }
                .environmentObject(appState)
                .environmentObject(authService)
            }
        }
        .sheet(isPresented: $showUserSearch) {
            UserSearchView()
        }
        .sheet(isPresented: $showDiary) {
            NavigationView { DiaryView() }
        }
        .sheet(isPresented: $showImport) {
            ImportView()
        }
        .fullScreenCover(isPresented: $showUpgradePaywall) {
            ProPaywallView(isPresented: $showUpgradePaywall, source: "profile_banner")
                .environmentObject(appState)
                .environmentObject(authService)
                .environmentObject(DailyQuotaManager.shared)
        }
        .sheet(isPresented: $showHelpSupport) {
            HelpSupportSheet()
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(selectedFeedbackType: $selectedFeedbackType)
        }
        .sheet(item: $selectedFeedbackType) { feedback in
            FeedbackDetailSheet(type: feedback) {
                selectedFeedbackType = nil
                showFeedback = true
            }
        }
    }
    
    private var authenticatedView: some View {
        ScrollView {
            VStack(spacing: 12) {
                profileHeader

                if gamificationService.isLoaded {
                    gamificationCard
                }

                statsTiles

                ProfileFavoritesSection { entry in
                    selectedFavorite = entry
                }

                settingsSection
            }
            .padding(.vertical, 20)
        }
        .sheet(isPresented: $showAnalyticsDashboard) {
            NavigationView { AnalyticsDashboardView() }
        }
        .sheet(item: $profileShareCard) { item in
            ShareCardSheet(content: item.content, onClose: { profileShareCard = nil })
        }
        .sheet(item: $selectedFavorite) { entry in
            NavigationStack {
                if entry.mediaType == "movie" {
                    MovieDetailView(movieId: entry.tmdbId)
                } else {
                    TVShowDetailView(tvShowId: entry.tmdbId)
                }
            }
            .environmentObject(appState)
            .environmentObject(dailyQuotaManager)
        }
        .sheet(isPresented: $showBadges) {
            // Redesign 2.0: la card livello e la riga "Badge e livelli" aprono la casa unica
            // della gamification; la galleria completa sta un livello dentro.
            GamificationProgressView(gamificationService: gamificationService)
        }
        .sheet(isPresented: $showNotificationPrefs) {
            NavigationView {
                NotificationPreferencesView(userId: appState.currentUser?.id ?? "")
            }
        }
        .sheet(isPresented: $showLanguageSelector) {
            LanguageSelectorView()
        }
        .sheet(isPresented: $showCacheSettings) {
            ImageCacheSettingsView()
        }
        .sheet(isPresented: $showPrivacyTerms) {
            PrivacyTermsView()
        }
    }

    // MARK: - Card livello (Redesign 2.0)

    /// Livello, rank e barra XP — il tap apre la galleria di badge e livelli.
    private var gamificationCard: some View {
        Button { showBadges = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [gamificationService.userState.rank.color,
                                         gamificationService.userState.rank.color.opacity(0.5)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)
                    Text("\(gamificationService.userState.currentLevel)")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\("gamification.level".localized) \(gamificationService.userState.currentLevel)")
                            .font(.system(size: 13.5, weight: .heavy))
                            .foregroundColor(.theme.textPrimary)
                        Text(gamificationService.userState.rank.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule()
                                .fill(Color.theme.accentOrange)
                                .frame(width: max(0, geo.size.width * gamificationService.userState.levelProgress))
                        }
                    }
                    .frame(height: 5)
                }

                Text("\(gamificationService.userState.xpProgressInLevel)/\(gamificationService.userState.xpNeededForNextLevel) XP")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.theme.accentOrange.opacity(0.16), Color.theme.accentOrange.opacity(0.05)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.theme.accentOrange.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 20)
    }

    // MARK: - Tiles stats (Redesign 2.0)

    /// Numeri del server, tre stati distinti (lezione di `ProfileStatsSection`): caricamento,
    /// numeri veri (zero compreso), fallimento CON riprova — mai zeri con la faccia di un dato.
    @ViewBuilder
    private var statsTiles: some View {
        switch serverStats.phase {
        case .loading:
            HStack { Spacer(); ProgressView().tint(.theme.accentOrange); Spacer() }
                .padding(.vertical, 10)
        case .failed:
            Button {
                Task { await serverStats.load() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("profile.stats.loadFailed".localized)
                        .font(.system(size: 13))
                }
                .foregroundColor(.theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        case .loaded(let stats):
            HStack(spacing: 8) {
                statTile(value: "\(stats.moviesWatched)", label: "profile.stats.movies".localized)
                statTile(value: "\(stats.episodesWatched)", label: "profile.stats.episodes".localized)
                statTile(value: Self.watchTimeText(stats.watchTimeSeconds),
                         label: "profile.stats.watchTime".localized, highlight: true)
                // "Library" = quota del tracciato già vista: metrica di backlog, locale per
                // natura (stessa tile della dashboard). Se le stats locali non sono ancora
                // state generate, al suo posto c'è un numero del server — mai una % inventata.
                if let local = analyticsService.userStats?.watchStats {
                    statTile(value: "\(Int(local.completionRate * 100))%", label: "Library")
                } else {
                    statTile(value: "\(stats.showsWatched)", label: "profile.stats.shows".localized)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func statTile(value: String, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(highlight ? .theme.accentOrange : .theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private static func watchTimeText(_ seconds: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: TimeInterval(seconds)) ?? "0"
    }
    
    private var unauthenticatedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.circle")
                .font(.system(size: 80))
                .foregroundColor(.theme.textSecondary)
            
            Text("profile.signInToVibeWatch".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("profile.signInDescription".localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showSignUp = true
            } label: {
                Text("profile.createAccount".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            
            Button {
                showSignIn = true
            } label: {
                Text("profile.signIn".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
        }
    }
    
    private var profileHeader: some View {
        VStack(spacing: 12) {
            if let avatarURL = appState.currentUser?.avatarURL,
               let url = URL(string: avatarURL) {
                CachedAsyncImage(url: url, maxPixelSize: 240) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                } placeholder: {
                    ProgressView()
                        .frame(width: 80, height: 80)
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.theme.textSecondary)
            }
            
            Text(displayNameOrEmail)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)

            // @username sotto il nome (prototipo 2.0): se manca — i 19 del backfill — la riga
            // non c'è, come per il link di condivisione.
            if let username = ownUsername {
                Text("@\(username)")
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
            } else if shouldShowEmailSubtitle {
                Text(appState.currentUser?.email ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }

            if let profileBio,
               !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(profileBio)
                    .font(.subheadline)
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }

            if let counts = socialCounts {
                HStack(spacing: 18) {
                    HStack(spacing: 5) {
                        Text("\(counts.followers)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.theme.textPrimary)
                        Text("social.profile.followers".localized)
                            .font(.system(size: 12.5))
                            .foregroundColor(.theme.textSecondary)
                    }
                    HStack(spacing: 5) {
                        Text("\(counts.following)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.theme.textPrimary)
                        Text("social.profile.following".localized)
                            .font(.system(size: 12.5))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
    }
    
    /// "Netflix +4": la prima piattaforma scelta e quante altre. Vuoto = niente valore.
    private var platformsValue: String? {
        let fromProviders = ProviderSelectionCodec.decodeNames(selectedProviderNamesData)
        let names = (fromProviders.isEmpty ? Set(selectedPlatforms.map(\.rawValue)) : fromProviders)
            .sorted()
        guard let first = names.first else { return nil }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    private var languageValue: String {
        "\(localizationManager.currentLanguage.nativeName) · \(localizationManager.currentCountry.id)"
    }

    private var cacheSizeValue: String {
        switch ImageCacheService.shared.getCurrentCacheSizePreference() {
        case .small: return "200 MB"
        case .medium: return "500 MB"
        case .large: return "1 GB"
        }
    }

    private var badgesSubtitle: String? {
        guard gamificationService.isLoaded else { return nil }
        let all = gamificationService.getAllBadgesWithProgress()
        return String(
            format: "profile.badgesLevels.subtitle".localized,
            gamificationService.userState.currentLevel,
            all.filter(\.isUnlocked).count,
            all.count
        )
    }

    private var settingsSection: some View {
        VStack(spacing: 12) {
            // Redesign 2.0: le righe si raggruppano per ruolo, come nel prototipo. La ricerca
            // utenti non è più qui: è la porta del tab Social, e una seconda porta nel profilo
            // sarebbe la copia che diverge.
            groupLabel("profile.group.activity".localized)
            groupCard {
                SettingsRow(icon: "chart.bar",
                            title: "profile.stats.title".localized,
                            subtitle: "profile.stats.subtitle".localized) {
                    showAnalyticsDashboard = true
                }

                rowDivider

                // §9.3: il diario. Si legge dalla cache locale (12 mesi, §5), zero rete.
                SettingsRow(icon: "book",
                            title: "diary.title".localized,
                            subtitle: "diary.subtitle".localized) {
                    showDiary = true
                }

                rowDivider

                SettingsRow(icon: "trophy",
                            title: "profile.badgesLevels".localized,
                            subtitle: badgesSubtitle) {
                    showBadges = true
                }

                rowDivider

                shareProfileRow

                // La card immagine accanto al link: il link porta AL profilo, la card lo
                // RACCONTA (avatar, preferiti, follower) su story/post. Senza username non
                // c'è pagina pubblica da firmare, e la riga non compare — come quella sopra.
                if ownUsername != nil {
                    shareProfileCardRow
                }
            }

            groupLabel("profile.group.preferences".localized)
            groupCard {
                // La riga apre le preferenze complete (tipi + ore silenziose): il toggle
                // secco che stava qui non diceva COSA si stava accendendo.
                SettingsRow(icon: "bell",
                            title: "profile.notifications".localized,
                            subtitle: "notifications.row.subtitle".localized,
                            value: (notificationService.notificationsEnabled
                                    ? "common.on" : "common.off").localized) {
                    showNotificationPrefs = true
                }

                rowDivider

                SettingsRow(icon: "play.tv",
                            title: "profile.streamingServices".localized,
                            subtitle: "platforms.row.subtitle".localized,
                            value: platformsValue) {
                    withAnimation {
                        showPlatformSelector = true
                    }
                }

                rowDivider

                SettingsRow(icon: "globe",
                            title: "profile.languageCountry".localized,
                            value: languageValue) {
                    showLanguageSelector = true
                }

                rowDivider

                SettingsRow(icon: "folder",
                            title: "profile.imageCache".localized,
                            subtitle: "profile.imageCache.subtitle".localized,
                            value: cacheSizeValue) {
                    showCacheSettings = true
                }

                rowDivider

                // SPEC v3 §7: l'import dello storico. La schermata è una lista di sorgenti
                // (oggi solo TV Time) apposta: gli import futuri sono righe, non schermate.
                SettingsRow(icon: "square.and.arrow.down", title: "profile.importFrom".localized) {
                    showImport = true
                }

            }

            groupLabel("profile.group.account".localized)
            groupCard {
                // Passa a Pro come riga arancione (prototipo) — il banner immagine è rimasto
                // solo dentro il paywall. Chi è già Pro non vede la riga.
                if !dailyQuotaManager.isProUser {
                    SettingsRow(icon: "crown",
                                title: "profile.upgradePro.title".localized,
                                subtitle: "profile.upgradePro.subtitle".localized,
                                textColor: .theme.accentOrange) {
                        showUpgradePaywall = true
                    }

                    rowDivider
                }

                SettingsRow(icon: "key.fill", title: "profile.changePassword".localized) {
                    showChangePassword = true
                }

                rowDivider

                SettingsRow(icon: "envelope", title: "profile.sendFeedback".localized) {
                    showFeedback = true
                }

                rowDivider

                SettingsRow(icon: "questionmark.circle", title: "profile.helpSupport".localized) {
                    showHelpSupport = true
                }

                rowDivider

                SettingsRow(icon: "shield", title: "profile.privacyTerms".localized) {
                    showPrivacyTerms = true
                }

                rowDivider

                SettingsRow(icon: "rectangle.portrait.and.arrow.right",
                            title: "profile.logout".localized,
                            iconColor: .red, textColor: .red) {
                    showLogoutConfirmation = true
                }
            }

            // L'attribuzione TMDb in fondo, come nel prototipo (ed è una condizione d'uso
            // dell'API, non un vezzo).
            Text("VibeWatch 2.0 · \("profile.footer.tmdb".localized)")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "55565c"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        }
        .alert("notifications.permissionRequired".localized, isPresented: $showNotificationAlert) {
            Button("notifications.openSettings".localized) {
                notificationService.openSettings()
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("notifications.enableInSettings".localized)
        }
        .confirmationDialog("notifications.disableConfirmation".localized, isPresented: $showDisableConfirmation, titleVisibility: .visible) {
            Button("notifications.disableButton".localized, role: .destructive) {
                Task {
                    await notificationService.disableNotifications()
                }
            }
            Button("common.cancel".localized, role: .cancel) {
                // Reset toggle back to enabled
                notificationService.notificationsEnabled = true
            }
        } message: {
            Text("notifications.disableMessage".localized)
        }
    }
    
    // MARK: - Gruppi (Redesign 2.0)

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .kerning(1.2)
            .foregroundColor(Color.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 10)
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
    }

    private var rowDivider: some View {
        Divider().background(Color.white.opacity(0.1))
    }

    private func handleNotificationToggle() {
        Task {
            defer { pendingNotificationToggle = false }
            
            if notificationService.notificationsEnabled {
                // User wants to enable notifications
                let success = await notificationService.enableNotifications()
                
                if !success {
                    // Permission denied - reset toggle and show alert
                    await MainActor.run {
                        notificationService.notificationsEnabled = false
                        showNotificationAlert = true
                    }
                }
            } else {
                // User wants to disable notifications - show confirmation
                await MainActor.run {
                    showDisableConfirmation = true
                }
            }
        }
    }
    
    private func handleLogout() async {
        do {
            try await authService.signOut()
            appState.isAuthenticated = false
            appState.currentUser = nil
        } catch {
            Logger.error("[ProfileView] Error logging out: \(error.localizedDescription)")
        }
    }
    
}

/// Redesign 2.0 — la riga del profilo come nel prototipo: icona in un cerchio tinto,
/// titolo con sottotitolo opzionale, valore a destra (es. "On", "Netflix +4"), chevron.
struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var iconColor: Color = .theme.accentOrange
    var textColor: Color = .theme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(textColor)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: "8a8b90"))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "6c6d73"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

struct HelpSupportSheet: View {
    // Termini e privacy vivono in `PrivacyTermsView`, che è la loro pagina: qui erano una
    // seconda copia degli stessi due link, e due posti che dicono la stessa cosa sono un posto
    // che prima o poi la dirà diversa.
    @Environment(\.dismiss) private var dismiss

    private var faqItems: [HelpFAQItem] {
        [
            HelpFAQItem(
                questionKey: "profile.faq.question1",
                answerKey: "profile.faq.answer1"
            ),
            HelpFAQItem(
                questionKey: "profile.faq.question2",
                answerKey: "profile.faq.answer2"
            ),
            HelpFAQItem(
                questionKey: "profile.faq.question3",
                answerKey: "profile.faq.answer3"
            ),
            HelpFAQItem(
                questionKey: "profile.faq.question4",
                answerKey: "profile.faq.answer4"
            ),
            HelpFAQItem(
                questionKey: "profile.faq.question5",
                answerKey: "profile.faq.answer5"
            )
        ]
    }

    @State private var expandedFAQ: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("profile.aboutUs".localized)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                        Text("profile.aboutUsDescription".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                        Text("profile.tmdbAttribution".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.top, 2)
                    }
                    .padding()
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("profile.faqs".localized)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.theme.textPrimary)

                        LazyVGrid(columns: [GridItem(.flexible())], spacing: 12) {
                            ForEach(faqItems) { item in
                                FAQChip(
                                    item: item,
                                    isExpanded: expandedFAQ == item.id
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        if expandedFAQ == item.id {
                                            expandedFAQ = nil
                                        } else {
                                            expandedFAQ = item.id
                                        }
                                    }
                                }
                            }
                        }
                    }

                }
                .padding(20)
            }
            .background(Color.theme.background)
            .navigationTitle("profile.helpSupport".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    BackCircleButton { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct HelpFAQItem: Identifiable {
    let questionKey: String
    let answerKey: String

    var id: String { questionKey }
    var question: String { questionKey.localized }
    var answer: String { answerKey.localized }
}

private struct FAQChip: View {
    let item: HelpFAQItem
    let isExpanded: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(item.question)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
                
                if isExpanded {
                    Text(item.answer)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isExpanded ? Color.theme.accentOrange : Color.white.opacity(0.08), lineWidth: isExpanded ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
struct FeedbackType: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    
    static let suggest = FeedbackType(
        id: "suggest",
        title: "profile.feedback.suggestFeature".localized,
        description: "profile.feedback.suggestFeatureDescription".localized,
        iconName: "lightbulb.fill"
    )
    static let bug = FeedbackType(
        id: "bug",
        title: "profile.feedback.reportBug".localized,
        description: "profile.feedback.reportBugDescription".localized,
        iconName: "ant.fill"
    )
    static let other = FeedbackType(
        id: "other",
        title: "profile.feedback.other".localized,
        description: "profile.feedback.otherDescription".localized,
        iconName: "bubble.left.fill"
    )
    
    static var all: [FeedbackType] { [.suggest, .bug, .other] }
}

struct FeedbackSheet: View {
    @Binding var selectedFeedbackType: FeedbackType?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VWModalSheet(
            title: "profile.sendFeedback".localized,
            subtitle: "profile.feedback.subtitle".localized,
            onClose: { dismiss() }
        ) {
            VStack(spacing: 12) {
                ForEach(FeedbackType.all) { type in
                    Button {
                        selectedFeedbackType = type
                        dismiss()
                    } label: {
                        row(for: type)
                    }
                    .buttonStyle(.plain)
                }

                Text(AppEnvironmentFootnote.text)
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
                    .padding(.top, 8)
            }
        }
        .vwModalPresentation()
    }

    private func row(for type: FeedbackType) -> some View {
        HStack(spacing: 14) {
            Image(systemName: type.iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.theme.accentOrange.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(type.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(type.description)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

/// "VibeWatch 2.4.1 (318) · iOS 18.5" — il piè di pagina delle modali di feedback.
enum AppEnvironmentFootnote {
    static var text: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "VibeWatch \(version) (\(build)) · iOS \(UIDevice.current.systemVersion)"
    }
}

/// Le categorie di "Segnala un problema": restringono il campo prima ancora di leggere il testo.
enum FeedbackCategory: String, CaseIterable, Identifiable {
    case crash
    case tvTimeImport
    case notifications
    case sync
    case ui
    case other

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .crash: return "profile.feedback.category.crash"
        case .tvTimeImport: return "profile.feedback.category.import"
        case .notifications: return "profile.feedback.category.notifications"
        case .sync: return "profile.feedback.category.sync"
        case .ui: return "profile.feedback.category.ui"
        case .other: return "profile.feedback.category.other"
        }
    }
}

struct FeedbackDetailSheet: View {
    let type: FeedbackType
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Il singleton e non `@EnvironmentObject`: questo foglio si apre anche dal dettaglio film,
    /// dove non c'è garanzia che l'oggetto sia stato iniettato nell'ambiente.
    private let appState = AppState.shared
    var onCancel: (() -> Void)? = nil
    @State private var message = ""
    @State private var keepUpdated = true
    @State private var isSending = false
    @State private var sendError: String?
    @State private var category: FeedbackCategory?

    private static let maxLength = 500

    var body: some View {
        VWModalSheet(
            title: type.title,
            subtitle: type.description,
            onBack: onCancel,
            onClose: { dismiss() },
            primaryTitle: "profile.feedback.sendButton".localized,
            primaryEnabled: canSend && !isSending,
            primaryAction: { Task { await sendFeedback() } }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if type.id == FeedbackType.bug.id {
                    FlowLayout(spacing: 8) {
                        ForEach(FeedbackCategory.allCases) { item in
                            categoryChip(item)
                        }
                    }
                }

                editor

                keepUpdatedCard

                if let sendError {
                    Text(sendError)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
            }
        }
        .vwModalPresentation()
    }

    private func categoryChip(_ item: FeedbackCategory) -> some View {
        Button {
            category = (category == item) ? nil : item
        } label: {
            Text(item.titleKey.localized)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(category == item ? .black : .theme.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(category == item
                                   ? Color.theme.accentOrange
                                   : Color.white.opacity(0.065))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(category == item ? 0 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 16))
                        .foregroundColor(.theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                }

                TextEditor(text: $message)
                    .scrollContentBackground(.hidden)
                    .frame(height: 130)
                    .foregroundColor(.theme.textPrimary)
                    .onChange(of: message) { _, newValue in
                        if newValue.count > Self.maxLength {
                            message = String(newValue.prefix(Self.maxLength))
                        }
                    }
            }

            Divider().overlay(Color.white.opacity(0.1))

            HStack {
                Spacer()
                Text("\(message.count)/\(Self.maxLength)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.theme.textSecondary)
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var placeholder: String {
        switch type.id {
        case FeedbackType.bug.id: return "profile.feedback.placeholder.bug".localized
        case FeedbackType.suggest.id: return "profile.feedback.placeholder.suggest".localized
        default: return "profile.feedback.placeholder.other".localized
        }
    }

    private var keepUpdatedCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("profile.feedback.keepUpdated".localized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                if let email = appState.currentUser?.email, !email.isEmpty {
                    Text(String(format: "profile.feedback.keepUpdatedEmail".localized, email))
                        .font(.system(size: 13.5))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $keepUpdated)
                .labelsHidden()
                .tint(.theme.accentOrange)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.065)))
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendFeedback() async {
        guard canSend else { return }
        isSending = true
        sendError = nil

        // Il canale resta quello di prima: una mail precompilata. Cambia solo ciò che ci
        // mettiamo dentro — categoria, versione e se l'utente vuole essere ricontattato.
        var subject = type.title
        if let category { subject += " · \(category.titleKey.localized)" }

        var body = message
        body += "\n\n---\n\(AppEnvironmentFootnote.text)"
        if keepUpdated, let email = appState.currentUser?.email, !email.isEmpty {
            body += "\n\(String(format: "profile.feedback.keepUpdatedEmail".localized, email))"
        }

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let mailtoString = "mailto:startingvibe2025@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)"

        guard let url = URL(string: mailtoString) else {
            sendError = "profile.feedback.invalidEmail".localized
            isSending = false
            return
        }

        openURL(url)
        ToastCenter.shared.show(success: "profile.feedback.sent".localized)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            dismiss()
        }

        isSending = false
    }
}
