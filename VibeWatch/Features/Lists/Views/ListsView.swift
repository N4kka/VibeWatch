import SwiftUI

enum ListTab: String, CaseIterable {
    case myLists = "My Lists"
    case watchlist = "Watchlist"
    case seen = "Seen"
    case liked = "Liked"
}

enum SortOption: String, CaseIterable {
    case title = "Title"
    case releaseDate = "Release Date"
    case dateAdded = "Date Added"
    case rating = "Rating"
}

struct ListsView: View {
    @StateObject private var viewModel = ListsViewModel()
    @State private var selectedTab: ListTab = .myLists
    @State private var selectedFilter: MediaFilter = .all
    @State private var showCreateList = false
    @State private var showSortPanel = false
    @State private var selectedSort: SortOption = .dateAdded
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    headerView
                    
                    tabSelector
                    
                    filterAndSortBar
                    
                    if viewModel.lists.isEmpty {
                        emptyStateView
                    } else {
                        contentView
                    }
                }
                
                if showSortPanel {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation {
                                showSortPanel = false
                            }
                        }
                    
                    VStack {
                        Spacer()
                        sortPanel
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationBarHidden(true)
        }
        .task {
            await viewModel.loadLists()
        }
        .sheet(isPresented: $showCreateList) {
            CreateListView()
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("My Lists")
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
    
    private var tabSelector: some View {
        HStack(spacing: 24) {
            ForEach(ListTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.system(size: 16, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .theme.accentOrange : .theme.textSecondary)
                        
                        if selectedTab == tab {
                            Rectangle()
                                .fill(Color.theme.accentOrange)
                                .frame(height: 2)
                                .transition(.scale)
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    private var filterAndSortBar: some View {
        HStack(spacing: 12) {
            FilterChip(
                title: "ALL",
                isSelected: selectedFilter == .all
            ) {
                selectedFilter = .all
            }
            
            FilterChip(
                title: "MOVIES",
                isSelected: selectedFilter == .movies
            ) {
                selectedFilter = .movies
            }
            
            FilterChip(
                title: "TV",
                isSelected: selectedFilter == .tvSeries
            ) {
                selectedFilter = .tvSeries
            }
            
            Spacer()
            
            Button {
                // View mode toggle
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20))
                    .foregroundColor(.theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showSortPanel.toggle()
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 20))
                    .foregroundColor(.theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
    
    private var sortPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sort By")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                
                Spacer()
                
                Button {
                    withAnimation {
                        showSortPanel = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            VStack(spacing: 0) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        withAnimation {
                            selectedSort = option
                            showSortPanel = false
                        }
                    } label: {
                        HStack {
                            Text(option.rawValue)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.theme.textPrimary)
                            
                            Spacer()
                            
                            if selectedSort == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.theme.accentOrange)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.clear)
                    }
                    
                    if option != SortOption.allCases.last {
                        Divider()
                            .background(Color.white.opacity(0.05))
                            .padding(.leading, 20)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color.theme.backgroundDark)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }
    
    private var contentView: some View {
        Group {
            switch selectedTab {
            case .myLists:
                listsGrid
            case .watchlist, .seen, .liked:
                mediaItemsList
            }
        }
    }
    
    private var listsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 16) {
                ForEach(filteredLists) { list in
                    ListCard(list: list)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
    }
    
    private var mediaItemsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sortedMediaItems) { item in
                    MediaItemCard(item: item)
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
            
            Text("No Lists Yet")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("Create your first list to start organizing your favorite content")
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showCreateList = true
            } label: {
                Text("Create List")
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
                    return item.type == .movie
                case .tvSeries:
                    return item.type == .tv
                case .all:
                    return true
                }
            }
            return hasType
        }
    }
    
    private var sortedMediaItems: [MediaListItem] {
        // Mock data for now - will be replaced with actual data from viewModel
        let items = viewModel.lists.flatMap { $0.items }
        let filtered = selectedFilter == .all ? items : items.filter { item in
            switch selectedFilter {
            case .movies: return item.type == .movie
            case .tvSeries: return item.type == .tv
            case .all: return true
            }
        }
        
        return filtered.sorted { item1, item2 in
            switch selectedSort {
            case .title:
                return item1.title < item2.title
            case .releaseDate:
                return (item1.releaseDate ?? "") > (item2.releaseDate ?? "")
            case .dateAdded:
                return item1.addedAt > item2.addedAt
            case .rating:
                return (item1.rating ?? 0) > (item2.rating ?? 0)
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isSelected ? .white : .theme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    isSelected ?
                    Color.theme.accentOrange :
                    Color.white.opacity(0.1)
                )
                .clipShape(Capsule())
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

struct ListCard: View {
    let list: MediaList
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color.theme.backgroundDark.opacity(0.5))
                .frame(height: 120)
                .overlay {
                    if list.items.isEmpty {
                        Image(systemName: "film")
                            .font(.system(size: 40))
                            .foregroundColor(.theme.textSecondary)
                    } else {
                        // TODO: Show grid of posters
                        Image(systemName: "rectangle.grid.2x2")
                            .font(.system(size: 40))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Text(list.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)
            
            Text("\(list.items.count) items")
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
        }
    }
}

struct CreateListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var listName = ""
    @State private var listDescription = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("List Name", text: $listName)
                    TextField("Description (Optional)", text: $listDescription)
                }
            }
            .navigationTitle("Create List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        // TODO: Create list
                        dismiss()
                    }
                    .disabled(listName.isEmpty)
                }
            }
        }
    }
}

struct MediaItemCard: View {
    let item: MediaListItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImageView(url: item.posterURL)
                .frame(width: 100, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    if let year = item.releaseDate?.prefix(4) {
                        Text(String(year))
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                    
                    if let rating = item.rating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 14))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }
                    
                    if let runtime = item.runtime {
                        Text("| \(runtime / 60)h \(runtime % 60)min")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(3)
                }
                
                Spacer()
            }
            
            Spacer()
            
            Button {
                // Toggle watched status
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(12)
        .background(Color.theme.backgroundDark)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

enum MediaFilter {
    case all
    case movies
    case tvSeries
}
