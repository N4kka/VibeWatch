import SwiftUI

struct ListsView: View {
    @StateObject private var viewModel = ListsViewModel()
    @StateObject private var availabilityService = ListAvailabilityService.shared
    @ObservedObject var localizationManager = LocalizationManager.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @EnvironmentObject var appState: AppState
    @State private var selectedSection: LibrarySection = .myLists
    @State private var selectedFilter: MediaFilter = .all
    @State private var selectedListType: ListViewType = .watchlist
    @State private var showCreateList = false
    @State private var showAuthGate = false
    @State private var showFilters = false
    @State private var showSearch = false
    @State private var showProfile = false
    @State private var refreshID = UUID()
    @State private var filters = GlobalDiscoveryFilters()

    @StateObject private var searchViewModel = SearchViewModel()

    @State private var filterRefreshTrigger = false
    @State private var showingPaywall = false
    @State private var itemsLimit = 50
    @State private var searchText = ""
    
    private var mediaFilterBinding: Binding<MediaFilter> {
        Binding(
            get: {
                switch filters.mediaType {
                case .both: return .all
                case .movies: return .movies
                case .tvShows: return .tvSeries
                }
            },
            set: { newValue in
                switch newValue {
                case .all: filters.mediaType = .both
                case .movies: filters.mediaType = .movies
                case .tvSeries: filters.mediaType = .tvShows
                }
            }
        )
    }
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                OfflineBanner()

                AppHeaderView(
                    onSearchTap: { showSearch = true },
                    onFilterTap: {
                        withAnimation { showFilters = true }
                    },
                    onProfileTap: { showProfile = true },
                    avatarURL: appState.currentUser?.avatarURL,
                    isProUser: quotaManager.isProUser,
                    activeFilterCount: filters.activeFilterCount
                )

                LibrarySectionSwitcher(selectedSection: $selectedSection)
                    .padding(.bottom, 8)

                if selectedSection == .myLists {
                    myListsContent
                } else {
                    TVShowsTrackingView()
                }
            }
        }
        .navigationBarHidden(true)
        .overlay {
            if showFilters {
                GlobalFilterView(
                    filters: $filters,
                    isPresented: $showFilters,
                    onApply: { _ in
                        filterRefreshTrigger.toggle()
                    }
                )
                .environmentObject(quotaManager)
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView(viewModel: searchViewModel)
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .task {
            await viewModel.loadLists()
            
            // Analytics: Track screen view
            AnalyticsService.shared.logScreenView(screenName: "Lists", screenClass: "ListsView")
        }
        .onChange(of: localizationManager.localeDidChange) {_, _ in
            Task { @MainActor in
                // Purge stale-locale detail cache so the next TMDB fetch returns
                // titles and overviews in the new language.
                await DetailCacheService.shared.clearAll()
                refreshID = UUID()
            }
        }
        .onChange(of: filters.streamingPlatforms) { _, platforms in
            if !platforms.isEmpty {
                 Task {
                     if let list = currentLists.first {
                         await availabilityService.checkAvailability(for: list.items, on: platforms)
                     }
                 }
            }
        }
        .onChange(of: currentLists.first?.id) { _, _ in
             if !filters.streamingPlatforms.isEmpty {
                 Task {
                     if let list = currentLists.first {
                         await availabilityService.checkAvailability(for: list.items, on: filters.streamingPlatforms)
                     }
                 }
             }
        }
        .id(refreshID)
        .sheet(isPresented: $showCreateList) {
            CreateListView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.theme.background)
        }
        .sheet(isPresented: $showAuthGate) {
            AuthenticationGateView(isPresented: $showAuthGate)
                .presentationBackground(.clear)
        }
        .fullScreenCover(isPresented: $showingPaywall) {
            DailyLimitPaywallView(isPresented: $showingPaywall, source: "list_limit")
        }
        .onChange(of: selectedListType) {
            // Reset limit when switching lists
            itemsLimit = 50
        }
    }
    private var myListsContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                ListTypeSwitcher(selectedType: $selectedListType)
                    .padding(.leading, 20)

                Spacer()

                Button {
                    guard appState.isAuthenticated else {
                        showAuthGate = true
                        return
                    }
                    if viewModel.canCreateList() {
                        showCreateList = true
                    } else {
                        showingPaywall = true
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.theme.accentOrange)
                }
                .padding(.trailing, 20)
            }
            .padding(.bottom, 16)

            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            combinedFiltersRow

            if viewModel.isLoadingInitial {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentLists.isEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
    }
    
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.theme.textSecondary)
            TextField("lists.searchPlaceholder".localized, text: $searchText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var currentLists: [MediaList] {
        var lists: [MediaList] = []
        
        switch selectedListType {
        case .myLists:
            lists = viewModel.customLists
        case .watchlist:
            lists = [viewModel.watchlist]
        case .seen:
            lists = [viewModel.seenList]
        case .liked:
            lists = [viewModel.likedList]
        }

        return lists
    }
    
    private var combinedFiltersRow: some View {
        HStack(spacing: 12) {
            // Media filter switcher
            MediaFilterSwitcher(selectedFilter: mediaFilterBinding)
            
            Spacer()
            
            // Advanced Filters Button with indicator
            Button {
                withAnimation {
                    showFilters = true
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                        Text("filters.title".localized)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                    
                    if filters.isActive {
                        Circle()
                            .fill(Color.theme.accentOrange)
                            .frame(width: 10, height: 10)
                            .offset(x: 4, y: -2)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
    
    private var contentView: some View {
        Group {
            if selectedListType == .myLists {
                listsGrid
            } else {
                itemsGrid
            }
        }
    }
    
    private var itemsGrid: some View {
        // Memoizzazione (2.4): paginatedItems (→ filter+sort) calcolato UNA volta per render.
        let paginated = paginatedItems
        return ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(paginated) { item in
                    MediaItemRow(
                        item: item,
                        isInSeenList: selectedListType == .seen,
                        onMarkAsSeen: {
                            Task {
                                if let currentList = currentLists.first {
                                    try? await viewModel.removeFromList(listId: currentList.id, itemId: item.id)
                                }

                                try await viewModel.addToList(listId: viewModel.seenList.id, movie: item.asMovie(), mediaType: item.mediaType)
                            }
                        },
                        onDelete: {
                            Task {
                                if let currentList = currentLists.first {
                                    try? await viewModel.removeFromList(listId: currentList.id, itemId: item.id)
                                }
                            }
                        }
                    )
                    .onAppear {
                        // When the last item appears, load more
                        if item.id == paginated.last?.id {
                            itemsLimit += 50
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .id(filterRefreshTrigger) // Force refresh when filters change
    }
    
    private var paginatedItems: [MediaListItem] {
        Array(filteredAndSortedItems.prefix(itemsLimit))
    }
    
    private var filteredAndSortedItems: [MediaListItem] {
        guard let list = currentLists.first else { return [] }
        return ListItemFilterer.filteredAndSorted(
            list.items,
            searchText: searchText,
            filters: filters,
            availabilityByItemId: availabilityService.availableItems,
            applyReleasePeriodFilter: true
        )
    }
    
    private var filteredAndSortedLists: [MediaList] {
        var lists = currentLists
        
        // Apply search filter
        if !searchText.isEmpty {
            lists = lists.filter { list in
                let nameMatch = list.displayName.range(of: searchText, options: .caseInsensitive) != nil
                let itemMatch = list.items.contains { $0.title.range(of: searchText, options: .caseInsensitive) != nil }
                return nameMatch || itemMatch
            }
        }
        
        // Apply sorting to list items within each list
        switch filters.sortBy {
        case .popularityDesc, .popularityAsc:
            lists = lists.map { list in
                var sortedList = list
                sortedList.items.sort { $0.addedAt > $1.addedAt }
                return sortedList
            }
        case .ratingDesc:
            lists = lists.map { list in
                var sortedList = list
                sortedList.items.sort { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
                return sortedList
            }
        case .ratingAsc:
            lists = lists.map { list in
                var sortedList = list
                sortedList.items.sort { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }
                return sortedList
            }
        case .releaseDateDesc:
            lists = lists.map { list in
                var sortedList = list
                sortedList.items.sort { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
                return sortedList
            }
        case .releaseDateAsc:
            lists = lists.map { list in
                var sortedList = list
                sortedList.items.sort { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
                return sortedList
            }
        }
        
        return lists
    }
    
    private var listsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 20) {
                ForEach(filteredAndSortedLists) { list in
                    NavigationLink(destination: CustomListDetailView(list: list)) {
                        ListCard(list: list)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.theme.textSecondary)
            
            Text("lists.empty".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("lists.emptyDescription".localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                guard appState.isAuthenticated else {
                    showAuthGate = true
                    return
                }
                showCreateList = true
            } label: {
                Text("lists.createList".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.theme.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 25))
            }
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }
    
    private var filteredLists: [MediaList] {
        guard filters.mediaType != .both else { return viewModel.lists }
        
        return viewModel.lists.filter { list in
            let hasType = list.items.contains { item in
                switch filters.mediaType {
                case .movies:
                    return item.mediaType == .movie
                case .tvShows:
                    return item.mediaType == .tv
                case .both:
                    return true
                }
            }
            return hasType
        }
    }
}

struct MediaItemRow: View {
    let item: MediaListItem
    let isInSeenList: Bool // From parent context (which list we're viewing)
    let onMarkAsSeen: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var listManager = ListManager.shared

    // Computed property to check if item is actually in seen list
    private var isActuallyInSeenList: Bool {
        listManager.isInList(
            listId: listManager.seenList.id,
            mediaId: item.mediaId,
            mediaType: item.mediaType
        )
    }
    @State private var topProvider: Provider?
    @State private var providerLink: String?
    @State private var navigateToDetail = false
    @State private var isLoadingProviders = false
    @State private var providerLookupCompleted = false
    @State private var showNotifyMeAlert = false
    @State private var offset: CGFloat = 0
    @State private var isSwiping = false
    @State private var cardWidth: CGFloat = 0
    @State private var fallbackOverview: String?
    @State private var fallbackSeasonCount: Int?
    @State private var fallbackDuration: Int?
    @State private var localizedTitle: String?
    @State private var localizedOverview: String?
    
    private var deleteThreshold: CGFloat {
        // Delete when swiped 75% of the card width
        return -(cardWidth * 0.75)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                // Delete button background (shown when swiping left)
                if offset < 0 {
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.red)
                            .frame(width: abs(offset))
                            .overlay(
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                                    .opacity(abs(offset) > 50 ? 1 : 0.5)
                            )
                    }
                    .frame(height: 204)
                }
                
                // Main content
                ZStack {
            // Background container
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.theme.accentOrange.opacity(0.2))
            
            HStack(alignment: .top, spacing: 16) {
                // Poster image - left side
                if let posterPath = item.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)") {
                    CachedAsyncImage(url: url, maxPixelSize: 630) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.theme.backgroundDark.opacity(0.5))
                    }
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Rectangle()
                        .fill(Color.theme.backgroundDark.opacity(0.5))
                        .frame(width: 120, height: 180)
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 30))
                                .foregroundColor(.theme.textSecondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12)) 
                }
                
                // Content - right side
                VStack(alignment: .leading, spacing: 8) {
                    // Title
                    Text(localizedTitle ?? item.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)
                    
                    let subtitleComponents = item.subtitleComponents(seasonCount: fallbackSeasonCount, duration: fallbackDuration)
                    if !subtitleComponents.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(subtitleComponents.enumerated()), id: \.offset) { index, component in
                                if index > 0 {
                                    Text("|")
                                }

                                if component.showsRatingStar {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.yellow)
                                }

                                Text(component.text)
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                    }

                    if let overview = localizedOverview ?? item.displayOverview(fallback: fallbackOverview) {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }
                    
                    Spacer()
                    
                    // Watch Now button
                    if isLoadingProviders || !providerLookupCompleted {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.theme.accentOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let provider = topProvider {
                        Button {
                            PlatformDeepLinkHelper.openPlatform(
                                provider: provider,
                                justWatchLink: providerLink,
                                title: item.title
                            )
                        } label: {
                            HStack {
                                CachedAsyncImage(url: provider.logoURL)
                                    .frame(width: 20, height: 20)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                
                                Text(String(format: "lists.watchOn".localized, provider.providerName.uppercased()))
                                    .font(.system(size: 12, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.theme.accentOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Button {
                            handleNotifyMe()
                        } label: {
                            HStack(spacing: 4) {
                                Text("lists.notifyMe".localized)
                                    .font(.system(size: 12, weight: .bold))
                                Text("🔔")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.theme.accentOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                
                // Checkmark button - top right
                VStack {
                    Button {
                        if isActuallyInSeenList {
                            // Remove from seen list - find the correct item ID in seen list
                            Task {
                                if let seenItem = listManager.seenList.items.first(where: { $0.mediaId == item.mediaId && $0.mediaType == item.mediaType }) {
                                    try? await listManager.removeFromList(
                                        listId: listManager.seenList.id,
                                        itemId: seenItem.id
                                    )
                                }
                            }
                        } else {
                            onMarkAsSeen()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isActuallyInSeenList ? Color.green.opacity(0.2) : Color.white.opacity(0.2))
                                .frame(width: 36, height: 36)

                            Image(systemName: isActuallyInSeenList ? "checkmark.circle.fill" : "checkmark")
                                .font(.system(size: isActuallyInSeenList ? 20 : 16, weight: .semibold))
                                .foregroundColor(isActuallyInSeenList ? .green : .theme.textSecondary)
                        }
                    }

                    Spacer()
                }
            }
            .padding(12)
            }
            .frame(height: 204)
            .offset(x: offset)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isSwiping {
                    navigateToDetail = true
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { gesture in
                        // Only activate swipe if horizontal movement is significantly more than vertical
                        let horizontalAmount = abs(gesture.translation.width)
                        let verticalAmount = abs(gesture.translation.height)
                        
                        // Check if this is primarily a horizontal gesture
                        if horizontalAmount > verticalAmount * 2 && gesture.translation.width < 0 {
                            isSwiping = true
                            // Limit the offset to the card width
                            let translation = gesture.translation.width
                            offset = max(translation, -cardWidth)
                        }
                    }
                    .onEnded { gesture in
                        let horizontalAmount = abs(gesture.translation.width)
                        let verticalAmount = abs(gesture.translation.height)
                        
                        // Only process as swipe if it was primarily horizontal
                        if horizontalAmount > verticalAmount * 2 {
                            withAnimation(.spring(response: 0.3)) {
                                if offset <= deleteThreshold {
                                    // Delete the item - slide all the way off screen
                                    offset = -cardWidth * 1.5
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        onDelete()
                                    }
                                } else {
                                    // Reset to original position
                                    offset = 0
                                }
                            }
                        } else {
                            // Was a vertical scroll, reset position
                            withAnimation(.spring(response: 0.3)) {
                                offset = 0
                            }
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isSwiping = false
                        }
                    }
            )
            .onAppear {
                cardWidth = geometry.size.width
            }
            }
        }
        .frame(height: 204)
        .navigationDestination(isPresented: $navigateToDetail) {
            destinationView
        }
        .task {
            await loadProviders()
        }
        .task(id: "\(item.mediaType.rawValue)-\(item.mediaId)") {
            await loadFallbackDisplayDataIfNeeded()
        }
        .alert("lists.notifyMeTitle".localized, isPresented: $showNotifyMeAlert) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text(String(format: "lists.notifyMeMessage".localized, item.title))
        }
    }
    
    private func handleNotifyMe() {
        showNotifyMeAlert = true
        
        // Ensure it's in watchlist
        Task {
            if !listManager.isInList(listId: listManager.watchlist.id, mediaId: item.mediaId, mediaType: item.mediaType) {
                try? await listManager.addToList(listId: listManager.watchlist.id, movie: item.asMovie(), mediaType: item.mediaType)
            }
            try? await LiveNotificationRepository.shared.toggleAlert(mediaId: item.mediaId, mediaType: item.mediaType, enabled: true)
        }
    }

    private func loadFallbackDisplayDataIfNeeded() async {
        fallbackOverview = nil
        fallbackSeasonCount = nil
        fallbackDuration = nil

        let needsOverview = item.displayOverview(fallback: nil) == nil
        let needsDuration = item.runtime == nil || item.runtime == 0
        let needsTVDetails = item.mediaType == .tv
        // localizedTitle == nil signals a fresh-locale fetch is needed (state was reset by
        // view recreation after locale change). In that case skip the early-return guard so
        // we always reach the TMDB call below.
        let needsLocalizedStrings = localizedTitle == nil
        guard needsOverview || needsDuration || needsTVDetails || needsLocalizedStrings else { return }

        switch item.mediaType {
        case .movie:
            for await detail in LocalMediaDetailRepository.shared.observeMovie(id: item.mediaId) {
                applyMovieDisplayFallback(detail.movie)
                // If we need fresh locale strings, don't trust the local cache — always
                // fall through to the TMDB call below.
                if !needsLocalizedStrings, !needsMovieNetworkFallback {
                    return
                }
            }
            if let movie = try? await TMDBService.shared.getMovieDetails(id: item.mediaId) {
                applyMovieDisplayFallback(movie)
            }
        case .tv:
            for await detail in LocalMediaDetailRepository.shared.observeTVShow(id: item.mediaId) {
                applyTVDisplayFallback(detail.tvShow)
                if !needsLocalizedStrings, !needsTVNetworkFallback {
                    return
                }
            }
            if let tvShow = try? await TMDBService.shared.getTVShowDetails(id: item.mediaId) {
                applyTVDisplayFallback(tvShow)
            }
        }
    }

    private var needsMovieNetworkFallback: Bool {
        item.displayOverview(fallback: fallbackOverview) == nil ||
        item.subtitle(seasonCount: fallbackSeasonCount, duration: fallbackDuration) == nil ||
        ((item.runtime == nil || item.runtime == 0) && fallbackDuration == nil)
    }

    private var needsTVNetworkFallback: Bool {
        item.displayOverview(fallback: fallbackOverview) == nil ||
        fallbackSeasonCount == nil ||
        fallbackDuration == nil
    }

    private func applyMovieDisplayFallback(_ movie: Movie) {
        if !movie.title.isEmpty {
            localizedTitle = movie.title
        }
        if !movie.overview.isEmpty {
            localizedOverview = movie.overview
        }

        if fallbackOverview == nil,
           let overview = item.displayOverview(fallback: movie.overview) {
            fallbackOverview = overview
        }

        if fallbackDuration == nil, let runtime = movie.runtime, runtime > 0 {
            fallbackDuration = runtime
        }
    }

    private func applyTVDisplayFallback(_ tvShow: TVShow) {
        if !tvShow.name.isEmpty {
            localizedTitle = tvShow.name
        }
        if !tvShow.overview.isEmpty {
            localizedOverview = tvShow.overview
        }

        if fallbackOverview == nil,
           let overview = item.displayOverview(fallback: tvShow.overview) {
            fallbackOverview = overview
        }

        if fallbackSeasonCount == nil, let numberOfSeasons = tvShow.numberOfSeasons, numberOfSeasons > 0 {
            fallbackSeasonCount = numberOfSeasons
        }

        if fallbackDuration == nil,
           let runtime = tvShow.episodeRunTime?.first(where: { $0 > 0 }) {
            fallbackDuration = runtime
        }
    }
    
    @ViewBuilder
    private var destinationView: some View {
        if item.mediaType == .movie {
            MovieDetailView(movieId: item.mediaId)
        } else {
            TVShowDetailView(tvShowId: item.mediaId)
        }
    }
    
    /// Load streaming providers via LiveWatchProvidersRepository (24h SQLite TTL).
    /// Only hits the network if the cached entry is expired or missing.
    private func loadProviders() async {
        guard !isLoadingProviders else { return }
        providerLookupCompleted = false
        topProvider = nil
        providerLink = nil
        isLoadingProviders = true
        let region = LocalizationManager.shared.currentCountry.id
        for await providers in LiveWatchProvidersRepository.shared.observeProviders(
            mediaId: item.mediaId, mediaType: item.mediaType, region: region
        ) {
            if let providers { processProviders(providers) }
        }
        isLoadingProviders = false
        providerLookupCompleted = true
    }

    private func processProviders(_ countryProviders: CountryProviders) {
        let result = ProviderSelection.selectTopProvider(from: countryProviders)
        providerLink = result.link
        // topProvider è aggiornato solo se troviamo un provider valido (non azzeriamo
        // quello già mostrato), come nel comportamento originale.
        if let top = result.top { topProvider = top }
    }
}

struct CustomListDetailView: View {
    let list: MediaList
    @StateObject private var listManager = ListManager.shared
    @StateObject private var availabilityService = ListAvailabilityService.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var filters = GlobalDiscoveryFilters()
    @State private var showFilters = false
    @State private var filterRefreshTrigger = false
    @State private var searchText = ""
    @State private var itemsLimit = 100
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var error: AppError?
    @Environment(\.dismiss) private var dismiss
    
    private var mediaFilterBinding: Binding<MediaFilter> {
        Binding(
            get: {
                switch filters.mediaType {
                case .both: return .all
                case .movies: return .movies
                case .tvShows: return .tvSeries
                }
            },
            set: { newValue in
                switch newValue {
                case .all: filters.mediaType = .both
                case .movies: filters.mediaType = .movies
                case .tvSeries: filters.mediaType = .tvShows
                }
            }
        )
    }

    private var currentList: MediaList {
        listManager.lists.first(where: { $0.id == list.id }) ?? list
    }

    private var filteredAndSortedItems: [MediaListItem] {
        // NB: applyReleasePeriodFilter:false preserva il comportamento STORICO di questo
        // struct, che (a differenza della list-detail principale) NON applicava il filtro
        // periodo/anno. Probabile bug latente da unificare — vedi ListItemFilterer.
        ListItemFilterer.filteredAndSorted(
            currentList.items,
            searchText: searchText,
            filters: filters,
            availabilityByItemId: availabilityService.availableItems,
            applyReleasePeriodFilter: false
        )
    }

    var body: some View {
        // Memoizzazione (2.4): filtro+sort calcolati UNA volta per render. Prima erano
        // ricalcolati separatamente da paginatedItems, .isEmpty e .count → 3-4 passate di
        // filter+sort sull'intera lista a ogni render.
        let items = filteredAndSortedItems
        let paginated = Array(items.prefix(itemsLimit))
        return ZStack(alignment: .top) {
            Color.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                HStack(spacing: 12) {
                    MediaFilterSwitcher(selectedFilter: mediaFilterBinding)
                    Spacer()
                    Button {
                        withAnimation { showFilters = true }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 14))
                                Text("filters.title".localized)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(.theme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())

                            if filters.isActive {
                                Circle()
                                    .fill(Color.theme.accentOrange)
                                    .frame(width: 10, height: 10)
                                    .offset(x: 4, y: -2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                if items.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 60))
                            .foregroundColor(.theme.textSecondary)

                        Text("lists.noItems".localized)
                            .font(.system(size: 16))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(paginated) { item in
                                MediaItemRow(
                                    item: item,
                                    isInSeenList: false,
                                    onMarkAsSeen: {
                                        Task {
                                            try? await listManager.removeFromList(listId: list.id, itemId: item.id)

                                            try await listManager.addToList(listId: listManager.seenList.id, movie: item.asMovie(), mediaType: item.mediaType)
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            try? await listManager.removeFromList(listId: list.id, itemId: item.id)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 100)
                    }
                    .overlay(alignment: .bottom) {
                        if items.count > paginated.count {
                            Button {
                                itemsLimit += 100
                            } label: {
                                Text("common.loadMore".localized)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                                    .background(Color.theme.accentOrange)
                                    .clipShape(Capsule())
                            }
                            .padding(.bottom, 24)
                        }
                    }
                    .id(filterRefreshTrigger)
                }
            }
        }
        .navigationTitle(currentList.displayName)
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if showFilters {
                GlobalFilterView(
                    filters: $filters,
                    isPresented: $showFilters,
                    onApply: { _ in
                        filterRefreshTrigger.toggle()
                    }
                )
                .environmentObject(quotaManager)
            }
        }
        .onChange(of: filters.streamingPlatforms) { _, platforms in
            if !platforms.isEmpty {
                 Task {
                     await availabilityService.checkAvailability(for: currentList.items, on: platforms)
                 }
            }
        }
        .onChange(of: currentList.items.count) { _, _ in
             if !filters.streamingPlatforms.isEmpty {
                 Task {
                     await availabilityService.checkAvailability(for: currentList.items, on: filters.streamingPlatforms)
                 }
             }
        }
        .onChange(of: filters) {_, _ in itemsLimit = 100 }
        .onChange(of: searchText) {_, _ in itemsLimit = 100 }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditListView(list: currentList)
        }
        .alert("lists.deleteList".localized, isPresented: $showDeleteAlert) {
            Button("common.delete".localized, role: .destructive) {
                Task { await deleteList() }
            }
            Button("common.cancel".localized, role: .cancel) { }
        } message: {
            Text("lists.deleteConfirmation".localized.replacingOccurrences(of: "%@", with: currentList.displayName))
        }
        .alert(item: $error) { appError in
            Alert(
                title: Text(appError.errorDescription ?? "common.error".localized),
                message: Text(appError.recoverySuggestion ?? "common.pleaseTryAgain".localized),
                dismissButton: .default(Text("common.ok".localized))
            )
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.theme.textSecondary)
            TextField("lists.searchPlaceholder".localized, text: $searchText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func deleteList() async {
        do {
            try await listManager.deleteList(id: currentList.id)
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                self.error = .database(error)
            }
        }
    }
}

struct ListCard: View {
    let list: MediaList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show thumbnail based on number of items
            if list.items.isEmpty {
                Rectangle()
                    .fill(Color.theme.backgroundDark.opacity(0.5))
                    .aspectRatio(2/3, contentMode: .fit)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 40))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if list.items.count < 4 {
                // Show last item's poster for 1-3 items
                if let lastItem = list.items.last,
                   let posterPath = lastItem.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)") {
                    CachedAsyncImage(url: url, maxPixelSize: 630) { image in
                        image
                            .resizable()
                            .aspectRatio(2/3, contentMode: .fit)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.theme.backgroundDark.opacity(0.5))
                            .aspectRatio(2/3, contentMode: .fit)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Rectangle()
                        .fill(Color.theme.backgroundDark.opacity(0.5))
                        .aspectRatio(2/3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                // Show 2x2 grid for 4+ items
                let lastFourItems = Array(list.items.suffix(4))
                GeometryReader { geometry in
                    let itemWidth = (geometry.size.width - 2) / 2  // 2px gap in middle
                    let itemHeight = itemWidth * 1.5  // 2:3 aspect ratio

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 2),
                        GridItem(.flexible(), spacing: 2)
                    ], spacing: 2) {
                        ForEach(lastFourItems) { item in
                            if let posterPath = item.posterPath,
                               let url = URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)") {
                                CachedAsyncImage(url: url, maxPixelSize: 630) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fit)
                                        .frame(width: itemWidth, height: itemHeight)
                                } placeholder: {
                                    Rectangle()
                                        .fill(Color.theme.backgroundDark.opacity(0.5))
                                        .frame(width: itemWidth, height: itemHeight)
                                }
                            } else {
                                Rectangle()
                                    .fill(Color.theme.backgroundDark.opacity(0.5))
                                    .frame(width: itemWidth, height: itemHeight)
                            }
                        }
                    }
                }
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text(list.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)

            Text("\(list.items.count) \("common.items".localized)")
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
        }
    }
}

struct CreateListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ListsViewModel
    @StateObject private var listManager = ListManager.shared
    @State private var listName = ""
    @State private var listDescription = ""
    @State private var error: AppError?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("lists.createList".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            .padding(20)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Content
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    // Limit Info
                    HStack {
                        Text("lists.limitInfo".localized
                            .replacingOccurrences(of: "{count}", with: "\(listManager.customListsCount())")
                            .replacingOccurrences(of: "{limit}", with: "\(listManager.currentCustomListLimit)"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(listManager.canCreateList() ? .theme.textSecondary : .theme.accentOrange)
                        
                        Spacer()
                    }
                    
                    // List Name Field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("lists.listName".localized)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.theme.textSecondary)
                        
                        TextField("lists.listNamePlaceholder".localized, text: $listName)
                            .font(.system(size: 16))
                            .foregroundColor(.theme.textPrimary)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Description Field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("lists.description".localized)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.theme.textSecondary)
                        
                        TextField("lists.descriptionPlaceholder".localized, text: $listDescription)
                            .font(.system(size: 16))
                            .foregroundColor(.theme.textPrimary)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
                
                Spacer()
                
                // Create Button
                Button {
                    Task {
                        do {
                            try await viewModel.createList(title: listName, description: listDescription.isEmpty ? nil : listDescription)
                            dismiss()
                        } catch {
                            self.error = .database(error)
                        }
                    }
                } label: {
                    Text("lists.createList".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(listName.isEmpty || !listManager.canCreateList() ? Color.gray.opacity(0.3) : Color.theme.accentOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(listName.isEmpty || !listManager.canCreateList())
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .alert(item: $error) { appError in
            Alert(
                title: Text(appError.errorDescription ?? "common.error".localized),
                message: Text(appError.recoverySuggestion ?? "common.pleaseTryAgain".localized),
                dismissButton: .default(Text("common.ok".localized))
                        )
                    }
                }
            }
            
            struct EditListView: View {
    @Environment(\.dismiss) private var dismiss
    let list: MediaList
    @StateObject private var listManager = ListManager.shared
    @State private var name: String
    @State private var description: String
    @State private var showError = false
    @State private var errorMessage = ""

    init(list: MediaList) {
        self.list = list
        _name = State(initialValue: list.name)
        _description = State(initialValue: list.description ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("lists.listName".localized)) {
                    TextField("lists.listNamePlaceholder".localized, text: $name)
                }
                Section(header: Text("lists.description".localized)) {
                    TextField("lists.descriptionPlaceholder".localized, text: $description)
                }
            }
            .navigationTitle("lists.editList".localized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save".localized) {
                        Task { await saveChanges() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("common.error".localized, isPresented: $showError) {
                Button("common.ok".localized, role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func saveChanges() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await listManager.updateList(id: list.id, name: trimmed, description: description.isEmpty ? nil : description)
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

struct PlatformChip: View {
    let platform: StreamingPlatform
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if let logoName = platform.logoAssetName {
                        Image(logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 60, height: 60)
                            .overlay(
                                Image(systemName: platform.icon)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(.white)
                            )
                    }
                    
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.theme.accentOrange : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
                        .frame(width: 60, height: 60)
                }
                
                Text(platform.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
    }
}

#Preview {
    ListsView()
}
