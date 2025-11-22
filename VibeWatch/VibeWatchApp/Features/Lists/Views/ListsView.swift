import SwiftUI

struct ListsView: View {
    @StateObject private var viewModel = ListsViewModel()
    @StateObject private var listManager = ListManager.shared
    @ObservedObject var localizationManager = LocalizationManager.shared
    @State private var selectedFilter: MediaFilter = .all
    @AppStorage("selectedPlatforms") private var selectedPlatformsData: Data = Data()
    @State private var selectedListType: ListViewType = .watchlist
    @State private var showCreateList = false
    @State private var showFilters = false
    @State private var refreshID = UUID()
    @State private var filters = DiscoveryFilters()
    
    // Swipe navigation
    @State private var horizontalOffset: CGFloat = 0
    @State private var isDraggingHorizontally = false
    @State private var filterRefreshTrigger = false
    
    private var selectedPlatforms: Set<StreamingPlatform> {
        get {
            if let decoded = try? JSONDecoder().decode(Set<String>.self, from: selectedPlatformsData) {
                return Set(decoded.compactMap { StreamingPlatform(rawValue: $0) })
            }
            return []
        }
    }
    
    private func togglePlatform(_ platform: StreamingPlatform) {
        var platforms = selectedPlatforms
        if platforms.contains(platform) {
            platforms.remove(platform)
        } else {
            platforms.insert(platform)
        }
        if let encoded = try? JSONEncoder().encode(platforms.map { $0.rawValue }) {
            selectedPlatformsData = encoded
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            
            ZStack {
                // Left view - Clips (visible when swiping right)
                if horizontalOffset > 0 {
                    ClipsView()
                        .offset(x: -screenWidth + horizontalOffset)
                }
                
                // Main content - Lists
                NavigationView {
                    ZStack {
                        Color.theme.background.ignoresSafeArea()
                        
                        VStack(spacing: 0) {
                            headerView
                            
                            ListTypeSwitcher(selectedType: $selectedListType)
                                .padding(.bottom, 16)
                            
                            combinedFiltersRow
                            
                            if currentLists.isEmpty {
                                emptyStateView
                            } else {
                                contentView
                            }
                        }
                    }
                    .navigationBarHidden(true)
                    .overlay {
                        if showFilters {
                            AdvancedFiltersPanel(
                                filters: $filters,
                                showRuntimeFilter: false,
                                onDismiss: {
                                    withAnimation {
                                        showFilters = false
                                    }
                                },
                                onApply: { _ in
                                    filterRefreshTrigger.toggle()
                                }
                            )
                        }
                    }
                }
                .task {
                    await viewModel.loadLists()
                }
                .onChange(of: localizationManager.localeDidChange) { _ in
                    refreshID = UUID()
                }
                .id(refreshID)
                .sheet(isPresented: $showCreateList) {
                    CreateListView(viewModel: viewModel)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Color.theme.backgroundDark.opacity(0.98))
                }
                .offset(x: horizontalOffset)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        let horizontalMovement = abs(value.translation.width)
                        let verticalMovement = abs(value.translation.height)
                        
                        // Only allow swipe right (to Clips), not left
                        if !isDraggingHorizontally && horizontalMovement > verticalMovement && horizontalMovement > 20 && value.translation.width > 0 {
                            isDraggingHorizontally = true
                        }
                        
                        if isDraggingHorizontally && value.translation.width > 0 {
                            horizontalOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        guard isDraggingHorizontally else { return }
                        
                        // Threshold: 30% of screen width (~100-130px)
                        if horizontalOffset > 100 {
                            // Swiped right - go to Clips
                            NotificationCenter.default.post(name: .navigateToClipsTab, object: nil)
                            horizontalOffset = 0
                            isDraggingHorizontally = false
                        } else {
                            // Reset with animation
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                horizontalOffset = 0
                            }
                            isDraggingHorizontally = false
                        }
                    }
            )
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("lists.myLists".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Spacer()
            
            Button {
                showCreateList = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    private var currentLists: [MediaList] {
        var lists: [MediaList] = []
        
        switch selectedListType {
        case .myLists:
            lists = listManager.lists.filter { $0.type == .custom }
        case .watchlist:
            lists = [listManager.watchlist]
        case .seen:
            lists = [listManager.seenList]
        case .liked:
            lists = [listManager.likedList]
        }
        
        return lists
    }
    
    private var combinedFiltersRow: some View {
        HStack(spacing: 12) {
            // Media filter switcher
            MediaFilterSwitcher(selectedFilter: $selectedFilter)
            
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
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(filteredAndSortedItems) { item in
                    MediaItemRow(
                        item: item,
                        isInSeenList: selectedListType == .seen,
                        onMarkAsSeen: {
                            // Remove from current list
                            if let currentList = currentLists.first {
                                listManager.removeFromList(listId: currentList.id, itemId: item.id)
                            }
                            
                            // Add to seen list
                            let movie = Movie(
                                id: item.mediaId,
                                title: item.title,
                                overview: "",
                                posterPath: item.posterPath,
                                backdropPath: nil,
                                releaseDate: nil,
                                voteAverage: 0.0,
                                voteCount: 0,
                                genreIds: nil,
                                genres: nil,
                                adult: false,
                                originalLanguage: "",
                                popularity: 0.0,
                                runtime: nil,
                                status: nil,
                                tagline: nil,
                                productionCountries: nil,
                                imdbId: nil
                            )
                            listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: item.mediaType)
                        },
                        onDelete: {
                            if let currentList = currentLists.first {
                                listManager.removeFromList(listId: currentList.id, itemId: item.id)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .id(filterRefreshTrigger) // Force refresh when filters change
    }
    
    private var filteredAndSortedItems: [MediaListItem] {
        guard let list = currentLists.first else { return [] }
        var items = list.items
        
        // Apply runtime filter (movies only)
        if filters.runtimeRange != .any {
            items = items.filter { item in
                guard item.mediaType == .movie, let runtime = item.runtime else { return false }
                
                if let minRuntime = filters.runtimeRange.minRuntime, runtime < minRuntime {
                    return false
                }
                if let maxRuntime = filters.runtimeRange.maxRuntime, runtime > maxRuntime {
                    return false
                }
                return true
            }
        }
        
        // Apply rating filter
        if filters.ratingRange != .any {
            items = items.filter { item in
                guard let voteAverage = item.voteAverage,
                      let minRating = filters.ratingRange.minRating else { return false }
                return voteAverage >= minRating
            }
        }
        
        // Apply country filter
        if let selectedCountry = filters.country {
            items = items.filter { item in
                guard let originCountry = item.originCountry else { return false }
                return originCountry.contains(selectedCountry)
            }
        }
        
        // Apply media type filter
        switch selectedFilter {
        case .all:
            break
        case .movies:
            items = items.filter { $0.mediaType == .movie }
        case .tvSeries:
            items = items.filter { $0.mediaType == .tv }
        }
        
        // Apply sorting
        switch filters.sortBy {
        case .popularityDesc, .popularityAsc:
            // Sort by date added as fallback (no popularity data stored)
            items.sort { $0.addedAt > $1.addedAt }
        case .ratingDesc:
            items.sort { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
        case .ratingAsc:
            items.sort { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }
        case .releaseDateDesc:
            items.sort { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        case .releaseDateAsc:
            items.sort { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
        }
        
        return items
    }
    
    private var filteredAndSortedLists: [MediaList] {
        var lists = currentLists
        
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
        guard selectedFilter != .all else { return viewModel.lists }
        
        return viewModel.lists.filter { list in
            let hasType = list.items.contains { item in
                switch selectedFilter {
                case .movies:
                    return item.mediaType == .movie
                case .tvSeries:
                    return item.mediaType == .tv
                case .all:
                    return true
                }
            }
            return hasType
        }
    }
}

struct MediaItemRow: View {
    let item: MediaListItem
    let isInSeenList: Bool
    let onMarkAsSeen: () -> Void
    let onDelete: () -> Void
    
    @StateObject private var listManager = ListManager.shared
    @State private var movieDetails: Movie?
    @State private var tvShowDetails: TVShow?
    @State private var navigateToDetail = false
    @State private var isLoadingDetails = false
    @State private var offset: CGFloat = 0
    @State private var isSwiping = false
    @State private var cardWidth: CGFloat = 0
    
    private let tmdbService = TMDBService.shared
    
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
                    AsyncImage(url: url) { image in
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
                    Text(item.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)
                    
                    // Metadata
                    if let movieDetails = movieDetails {
                        HStack(spacing: 8) {
                            if let year = movieDetails.year {
                                Text(year)
                                    .font(.system(size: 13))
                                    .foregroundColor(.theme.textSecondary)
                            }
                            
                            if movieDetails.voteAverage > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.yellow)
                                    Text(String(format: "%.1f", movieDetails.voteAverage))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.theme.textPrimary)
                                }
                            }
                            
                            if let runtime = movieDetails.formattedRuntime {
                                Text("| \(runtime)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.theme.textSecondary)
                            }
                        }
                        
                        Text(movieDetails.overview)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(3)
                            .padding(.top, 4)
                    } else if let tvShowDetails = tvShowDetails {
                        HStack(spacing: 8) {
                            if let year = tvShowDetails.year {
                                Text(year)
                                    .font(.system(size: 13))
                                    .foregroundColor(.theme.textSecondary)
                            }
                            
                            if tvShowDetails.voteAverage > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.yellow)
                                    Text(String(format: "%.1f", tvShowDetails.voteAverage))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.theme.textPrimary)
                                }
                            }
                        }
                        
                        Text(tvShowDetails.overview)
                            .font(.system(size: 13))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }
                    
                    Spacer()
                    
                    // Watch Now button
                    Button {
                        // TODO: Open streaming link
                    } label: {
                        HStack {
                            Image(systemName: "play.tv")
                                .font(.system(size: 16))
                            Text("movieDetail.watchNow".localized.uppercased())
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                
                // Checkmark button - top right
                VStack {
                    Button {
                        if isInSeenList {
                            // Remove from seen list
                            if let currentList = listManager.lists.first(where: { $0.type == .seen }) {
                                listManager.removeFromList(listId: currentList.id, itemId: item.id)
                            }
                        } else {
                            onMarkAsSeen()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isInSeenList ? Color.green.opacity(0.2) : Color.white.opacity(0.2))
                                .frame(width: 36, height: 36)
                            
                            Image(systemName: isInSeenList ? "checkmark.circle.fill" : "checkmark")
                                .font(.system(size: isInSeenList ? 20 : 16, weight: .semibold))
                                .foregroundColor(isInSeenList ? .green : .theme.textSecondary)
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
            .gesture(
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
        .background(
            NavigationLink(
                destination: destinationView,
                isActive: $navigateToDetail
            ) {
                EmptyView()
            }
            .hidden()
        )
        .task {
            await loadDetails()
        }
    }
    
    private func loadDetails() async {
        guard !isLoadingDetails else { return }
        isLoadingDetails = true
        
        do {
            if item.mediaType == .movie {
                movieDetails = try await tmdbService.getMovieDetails(id: item.mediaId)
            } else {
                tvShowDetails = try await tmdbService.getTVShowDetails(id: item.mediaId)
            }
        } catch {
            print("Error loading details: \(error)")
        }
        
        isLoadingDetails = false
    }
    
    @ViewBuilder
    private var destinationView: some View {
        if item.mediaType == .movie {
            MovieDetailView(movieId: item.mediaId)
        } else {
            TVShowDetailView(tvShowId: item.mediaId)
        }
    }
}

struct CustomListDetailView: View {
    let list: MediaList
    @StateObject private var listManager = ListManager.shared
    @State private var selectedFilter: MediaFilter = .all
    @State private var filters = DiscoveryFilters()
    @State private var showFilters = false
    @State private var filterRefreshTrigger = false
    @Environment(\.dismiss) private var dismiss

    // Sort the single list’s items according to filters.sortBy (used if needed elsewhere)
    private var filteredAndSortedLists: [MediaList] {
        var sortedList = list
        sortedList.items.sort { item1, item2 in
            switch filters.sortBy {
            case .popularityDesc:
                return item1.addedAt > item2.addedAt
            case .popularityAsc:
                return item1.addedAt < item2.addedAt
            case .ratingDesc:
                return (item1.voteAverage ?? 0) > (item2.voteAverage ?? 0)
            case .ratingAsc:
                return (item1.voteAverage ?? 0) < (item2.voteAverage ?? 0)
            case .releaseDateDesc:
                return (item1.releaseDate ?? "") > (item2.releaseDate ?? "")
            case .releaseDateAsc:
                return (item1.releaseDate ?? "") < (item2.releaseDate ?? "")
            }
        }
        return [sortedList]
    }
    
    // Full filter + sort for the visible items in this list
    private var filteredAndSortedItems: [MediaListItem] {
        var items = list.items
        
        // Runtime filter (movies only)
        if filters.runtimeRange != .any {
            items = items.filter { item in
                guard item.mediaType == .movie, let runtime = item.runtime else { return false }
                if let minRuntime = filters.runtimeRange.minRuntime, runtime < minRuntime { return false }
                if let maxRuntime = filters.runtimeRange.maxRuntime, runtime > maxRuntime { return false }
                return true
            }
        }
        
        // Rating filter
        if filters.ratingRange != .any {
            items = items.filter { item in
                guard let voteAverage = item.voteAverage,
                      let minRating = filters.ratingRange.minRating else { return false }
                return voteAverage >= minRating
            }
        }
        
        // Country filter
        if let selectedCountry = filters.country {
            items = items.filter { item in
                guard let originCountry = item.originCountry else { return false }
                return originCountry.contains(selectedCountry)
            }
        }
        
        // Media type filter
        switch selectedFilter {
        case .all:
            break
        case .movies:
            items = items.filter { $0.mediaType == .movie }
        case .tvSeries:
            items = items.filter { $0.mediaType == .tv }
        }
        
        // Sorting
        switch filters.sortBy {
        case .popularityDesc, .popularityAsc:
            items.sort { $0.addedAt > $1.addedAt }
        case .ratingDesc:
            items.sort { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
        case .ratingAsc:
            items.sort { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }
        case .releaseDateDesc:
            items.sort { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        case .releaseDateAsc:
            items.sort { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
        }
        
        return items
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Filter bar
                HStack(spacing: 12) {
                    MediaFilterSwitcher(selectedFilter: $selectedFilter)

                    Spacer()

                    // Advanced Filters Button
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
                .padding(.vertical, 12)

                // Items list
                if filteredAndSortedItems.isEmpty {
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
                            ForEach(filteredAndSortedItems) { item in
                                MediaItemRow(
                                    item: item,
                                    isInSeenList: false,
                                    onMarkAsSeen: {
                                        // Remove from current list
                                        listManager.removeFromList(listId: list.id, itemId: item.id)

                                        // Add to seen list
                                        let movie = Movie(
                                            id: item.mediaId,
                                            title: item.title,
                                            overview: "",
                                            posterPath: item.posterPath,
                                            backdropPath: nil,
                                            releaseDate: nil,
                                            voteAverage: 0.0,
                                            voteCount: 0,
                                            genreIds: nil,
                                            genres: nil,
                                            adult: false,
                                            originalLanguage: "",
                                            popularity: 0.0,
                                            runtime: nil,
                                            status: nil,
                                            tagline: nil,
                                            productionCountries: nil,
                                            imdbId: nil
                                        )
                                        listManager.addToList(listId: listManager.seenList.id, movie: movie, mediaType: item.mediaType)
                                    },
                                    onDelete: {
                                        listManager.removeFromList(listId: list.id, itemId: item.id)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 100)
                    }
                    .id(filterRefreshTrigger) // Force refresh when filters change
                }
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if showFilters {
                AdvancedFiltersPanel(
                    filters: $filters,
                    showRuntimeFilter: false,
                    onDismiss: {
                        withAnimation {
                            showFilters = false
                        }
                    },
                    onApply: { _ in
                        // Force view refresh when filters are applied
                        filterRefreshTrigger.toggle()
                    }
                )
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
                    AsyncImage(url: url) { image in
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
                                AsyncImage(url: url) { image in
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

            Text(list.name)
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
    @State private var showError = false
    @State private var errorMessage = ""
    
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
                            .replacingOccurrences(of: "{limit}", with: "\(ListManager.maxCustomLists)"))
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
                        let result = await viewModel.createList(title: listName, description: listDescription.isEmpty ? nil : listDescription)
                        switch result {
                        case .success:
                            dismiss()
                        case .failure(let error):
                            errorMessage = error.localizedDescription
                            showError = true
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
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(platform.color)
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: platform.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.theme.accentOrange : Color.clear, lineWidth: 3)
                )
                
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
