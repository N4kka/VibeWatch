import SwiftUI

struct ListsView: View {
    @StateObject private var viewModel = ListsViewModel()
    @State private var selectedFilter: MediaFilter = .all
    @State private var showCreateList = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    headerView
                    
                    filterSelector
                    
                    if viewModel.lists.isEmpty {
                        emptyStateView
                    } else {
                        listsGrid
                    }
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
    
    private var filterSelector: some View {
        HStack(spacing: 12) {
            FilterChip(
                title: "All",
                isSelected: selectedFilter == .all
            ) {
                selectedFilter = .all
            }
            
            FilterChip(
                title: "Movies",
                isSelected: selectedFilter == .movies
            ) {
                selectedFilter = .movies
            }
            
            FilterChip(
                title: "TV Series",
                isSelected: selectedFilter == .tvSeries
            ) {
                selectedFilter = .tvSeries
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
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

enum MediaFilter {
    case all
    case movies
    case tvSeries
}
