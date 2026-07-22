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
    @State private var showInlineSearch = false
    @FocusState private var searchFieldFocused: Bool
    @State private var forkedList: MediaList?

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
    
    /// Crea una lista pubblicabile a partire dalla lista core attualmente visualizzata
    /// (snapshot scollegato): apre l'editor sulla nuova lista per rinominarla e renderla pubblica.
    private func duplicateCurrentCoreList() {
        guard appState.isAuthenticated else { showAuthGate = true; return }
        guard let source = currentLists.first else { return }
        guard viewModel.canCreateList() else { showingPaywall = true; return }
        Task {
            let copyName = String(format: "lists.duplicateName".localized, source.displayName)
            if let newList = try? await ListManager.shared.duplicateAsNewList(from: source.id, name: copyName) {
                await MainActor.run { forkedList = newList }
            }
        }
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                OfflineBanner()

                // No filter button here: the Lists tab has its own inline "Filtri" control,
                // so the header keeps just search + avatar (one door to the filter sheet).
                AppHeaderView(
                    onSearchTap: { showSearch = true },
                    onProfileTap: { showProfile = true },
                    avatarURL: appState.currentUser?.avatarURL,
                    isProUser: quotaManager.isProUser
                )

                LibrarySectionSwitcher(selectedSection: $selectedSection)
                    .padding(.bottom, 8)

                if selectedSection == .myLists {
                    myListsContent
                } else if selectedSection == .tvTracking {
                    TVShowsTrackingView()
                } else {
                    PublicListsView()
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
        .sheet(item: $forkedList) { newList in
            EditListView(list: newList)
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

                if selectedListType != .myLists {
                    Menu {
                        Button {
                            duplicateCurrentCoreList()
                        } label: {
                            Label("lists.public.createFromThis".localized, systemImage: "square.on.square")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 24))
                            .foregroundColor(.theme.accentOrange)
                    }
                    .padding(.trailing, 12)
                }

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

            combinedFiltersRow

            if showInlineSearch {
                searchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if viewModel.isLoadingInitial && viewModel.lists.isEmpty {
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
                .focused($searchFieldFocused)

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
        HStack(spacing: 10) {
            // Quick media filter (fast path; stays in sync with the Filtri sheet)
            MediaFilterSwitcher(selectedFilter: mediaFilterBinding)

            Spacer()

            // Search this list — collapses to an icon, expands inline on tap
            ListsFilterRow.searchToggle(isOn: showInlineSearch) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInlineSearch.toggle()
                    if showInlineSearch {
                        searchFieldFocused = true
                    } else {
                        searchText = ""
                        searchFieldFocused = false
                    }
                }
            }

            // Advanced filters — single door to GlobalFilterView, with active-count badge
            ListsFilterRow.filtersButton(count: filters.activeFilterCount) {
                withAnimation { showFilters = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
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
    /// Liste pubbliche altrui: nasconde il checkmark "visto" e disabilita lo swipe-to-delete.
    var isReadOnly: Bool = false

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
    @State private var ambientTint: Color = .clear

    /// Card geometry — tighter than before so ~3–4 cards breathe per screen.
    private let cardHeight: CGFloat = 180
    private let posterWidth: CGFloat = 104
    private let posterHeight: CGFloat = 156

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
                    .frame(height: cardHeight)
                }

                // Main content
                ZStack {
            // Background container — neutral surface with a faint per-poster ambient wash
            // at the poster (leading) edge, plus a hairline border. The wash is the
            // "signature": each row picks up its own film's dominant color, subtly.
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [ambientTint.opacity(0.34), .clear],
                                startPoint: .leading,
                                endPoint: UnitPoint(x: 0.42, y: 0.5)
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )

            HStack(alignment: .top, spacing: 14) {
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
                    .frame(width: posterWidth, height: posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                } else {
                    Rectangle()
                        .fill(Color.theme.backgroundDark.opacity(0.5))
                        .frame(width: posterWidth, height: posterHeight)
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 30))
                                .foregroundColor(.theme.textSecondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                
                // Content - right side
                VStack(alignment: .leading, spacing: 7) {
                    // Title
                    Text(localizedTitle ?? item.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)
                        .padding(.trailing, 34)
                    
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
                            .lineLimit(2)
                            .padding(.top, 2)
                    }

                    Spacer(minLength: 4)

                    // Watch action — a compact chip, not a full-width orange bar.
                    // checking → quiet skeleton · available → provider chip · unknown → notify chip
                    if isLoadingProviders || !providerLookupCompleted {
                        providerSkeletonChip
                    } else if let provider = topProvider {
                        Button {
                            PlatformDeepLinkHelper.openPlatform(
                                provider: provider,
                                justWatchLink: providerLink,
                                title: item.title
                            )
                        } label: {
                            HStack(spacing: 7) {
                                CachedAsyncImage(url: provider.logoURL)
                                    .frame(width: 22, height: 22)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                Text(provider.providerName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.theme.textPrimary)
                            .padding(.leading, 8)
                            .padding(.trailing, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
                        }
                    } else {
                        Button {
                            handleNotifyMe()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bell")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("lists.notifyMe".localized)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
                        }
                    }
                }
                
                // Checkmark button - top right
                if !isReadOnly {
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
                                .fill(isActuallyInSeenList ? Color.theme.accentOrange : Color.white.opacity(0.07))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.07), lineWidth: isActuallyInSeenList ? 0 : 1)
                                )

                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isActuallyInSeenList ? .white : .theme.textSecondary)
                        }
                    }

                    Spacer()
                }
                }
            }
            .padding(12)
            }
            .frame(height: cardHeight)
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
                        guard !isReadOnly else { return }
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
        .frame(height: cardHeight)
        .navigationDestination(isPresented: $navigateToDetail) {
            destinationView
        }
        .task {
            await loadProviders()
        }
        .task(id: "\(item.mediaType.rawValue)-\(item.mediaId)") {
            await loadFallbackDisplayDataIfNeeded()
        }
        .task(id: item.posterPath) {
            await loadAmbientTint()
        }
        .alert("lists.notifyMeTitle".localized, isPresented: $showNotifyMeAlert) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text(String(format: "lists.notifyMeMessage".localized, item.title))
        }
    }
    
    /// Quiet placeholder shown while streaming availability is still being looked up —
    /// replaces the old loud orange spinner bar.
    private var providerSkeletonChip: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.10))
                .frame(width: 22, height: 22)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.10))
                .frame(width: 72, height: 10)
        }
        .shimmering()
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    /// Sample a subtle ambient tint from the poster (computed once, memoized by URL).
    private func loadAmbientTint() async {
        guard let posterPath = item.posterPath,
              let url = URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)") else { return }
        let key = url.absoluteString
        if let hit = PosterTint.cached(for: key) {
            ambientTint = hit
            return
        }
        if let image = try? await ImageCacheService.shared.loadImage(from: key, maxPixelSize: 120) {
            let tint = PosterTint.compute(from: image, key: key)
            await MainActor.run { ambientTint = tint }
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
    @State private var showInlineSearch = false
    @FocusState private var searchFieldFocused: Bool
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
        // Fix bug filtro: ora applica il filtro periodo/anno come la list-detail principale.
        // Storicamente questo struct lo OMETTEVA (omissione copia-incolla), così il filtro
        // periodo non aveva effetto nelle liste custom. Unificato a `true` — vedi ListItemFilterer.
        ListItemFilterer.filteredAndSorted(
            currentList.items,
            searchText: searchText,
            filters: filters,
            availabilityByItemId: availabilityService.availableItems,
            applyReleasePeriodFilter: true
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
                HStack(spacing: 10) {
                    MediaFilterSwitcher(selectedFilter: mediaFilterBinding)

                    Spacer()

                    ListsFilterRow.searchToggle(isOn: showInlineSearch) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showInlineSearch.toggle()
                            if showInlineSearch {
                                searchFieldFocused = true
                            } else {
                                searchText = ""
                                searchFieldFocused = false
                            }
                        }
                    }

                    ListsFilterRow.filtersButton(count: filters.activeFilterCount) {
                        withAnimation { showFilters = true }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)

                if showInlineSearch {
                    searchField
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

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
                if currentList.isPublic {
                    Image(systemName: "globe")
                        .foregroundColor(.theme.accentOrange)
                }
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
                .focused($searchFieldFocused)

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

            HStack(spacing: 6) {
                if list.isPublic {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                }
                Text(list.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
            }

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
    @State private var isPublic = false
    @State private var showGuidelines = false
    @State private var showProfanityError = false
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

                    // Visibilità pubblica (solo liste custom)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $isPublic) {
                            Text("lists.public.toggle".localized)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.theme.textPrimary)
                        }
                        .tint(.theme.accentOrange)

                        Text("lists.public.toggle.footer".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                .padding(20)
                
                Spacer()
                
                // Create Button
                Button {
                    attemptCreate()
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
        .alert("lists.public.profanity.title".localized, isPresented: $showProfanityError) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text("lists.public.profanity".localized)
        }
        .alert("lists.public.guidelines.title".localized, isPresented: $showGuidelines) {
            Button("lists.public.guidelines.accept".localized) {
                UserDefaults.standard.set(true, forKey: EditListView.guidelinesKey)
                Task { await performCreate() }
            }
            Button("common.cancel".localized, role: .cancel) { }
        } message: {
            Text("lists.public.guidelines.body".localized)
        }
                }

    private func attemptCreate() {
        if isPublic {
            guard ProfanityFilter.validateForPublishing(name: listName, description: listDescription.isEmpty ? nil : listDescription) else {
                showProfanityError = true
                return
            }
            if !UserDefaults.standard.bool(forKey: EditListView.guidelinesKey) {
                showGuidelines = true
                return
            }
        }
        Task { await performCreate() }
    }

    private func performCreate() async {
        do {
            let newList = try await listManager.createList(name: listName, description: listDescription.isEmpty ? nil : listDescription)
            if isPublic {
                try await listManager.setListVisibility(listId: newList.id, isPublic: true)
            }
            dismiss()
        } catch {
            self.error = .database(error)
        }
    }
            }

struct EditListView: View {
    @Environment(\.dismiss) private var dismiss
    let list: MediaList
    @StateObject private var listManager = ListManager.shared
    @State private var name: String
    @State private var description: String
    @State private var isPublic: Bool
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showGuidelines = false

    static let guidelinesKey = "publicListsGuidelinesAccepted"

    init(list: MediaList) {
        self.list = list
        _name = State(initialValue: list.name)
        _description = State(initialValue: list.description ?? "")
        _isPublic = State(initialValue: list.isPublic)
    }

    private var canPublishContent: Bool {
        ProfanityFilter.validateForPublishing(name: name, description: description.isEmpty ? nil : description)
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
                if list.type == .custom {
                    Section(footer: Text("lists.public.toggle.footer".localized)) {
                        Toggle("lists.public.toggle".localized, isOn: $isPublic)
                    }
                }
            }
            .navigationTitle("lists.editList".localized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save".localized) { attemptSave() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("common.error".localized, isPresented: $showError) {
                Button("common.ok".localized, role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .alert("lists.public.guidelines.title".localized, isPresented: $showGuidelines) {
                Button("lists.public.guidelines.accept".localized) {
                    UserDefaults.standard.set(true, forKey: Self.guidelinesKey)
                    Task { await saveChanges() }
                }
                Button("common.cancel".localized, role: .cancel) { }
            } message: {
                Text("lists.public.guidelines.body".localized)
            }
        }
    }

    private func attemptSave() {
        if isPublic {
            guard canPublishContent else {
                errorMessage = "lists.public.profanity".localized
                showError = true
                return
            }
            // Consenso linee guida UGC al primo publish (App Store 1.2).
            if !list.isPublic && !UserDefaults.standard.bool(forKey: Self.guidelinesKey) {
                showGuidelines = true
                return
            }
        }
        Task { await saveChanges() }
    }

    private func saveChanges() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await listManager.updateList(id: list.id, name: trimmed, description: description.isEmpty ? nil : description)
            if list.type == .custom && isPublic != list.isPublic {
                try await listManager.setListVisibility(listId: list.id, isPublic: isPublic)
            }
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
