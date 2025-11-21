import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @State private var selectedResult: SearchResult?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    SearchBarView(
                        searchQuery: $viewModel.searchQuery,
                        isSearchFocused: $isSearchFocused,
                        onDismiss: { dismiss() }
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .onChange(of: viewModel.searchQuery) {
                        viewModel.search()
                    }
                    
                    ScrollView {
                        VStack(spacing: 24) {
                            if viewModel.searchQuery.isEmpty {
                                TrendingSearchesSection(
                                    results: viewModel.trendingSearches,
                                    onTap: { result in
                                        selectedResult = result
                                    }
                                )
                            } else {
                                SearchResultsSection(
                                    results: viewModel.searchResults,
                                    isLoading: viewModel.isLoading,
                                    onTap: { result in
                                        selectedResult = result
                                    }
                                )
                            }
                        }
                        .padding(.top, 16)
                    }
                }
            }
            .navigationDestination(item: $selectedResult) { result in
                if result.mediaType == "movie" {
                    MovieDetailView(movieId: result.id)
                } else {
                    TVShowDetailView(tvShowId: result.id)
                }
            }
        }
        .onAppear {
            isSearchFocused = true
        }
    }
}

struct SearchBarView: View {
    @Binding var searchQuery: String
    var isSearchFocused: FocusState<Bool>.Binding
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
            }
            
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.theme.textSecondary)
                
                TextField("search.placeholder".localized, text: $searchQuery)
                    .foregroundColor(.theme.textPrimary)
                    .focused(isSearchFocused)
                    .autocorrectionDisabled()
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct TrendingSearchesSection: View {
    let results: [SearchResult]
    let onTap: (SearchResult) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("search.trendingSearches".localized)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 20)
            
            LazyVStack(spacing: 12) {
                ForEach(results) { result in
                    SearchResultRow(result: result)
                        .onTapGesture {
                            onTap(result)
                        }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct SearchResultsSection: View {
    let results: [SearchResult]
    let isLoading: Bool
    let onTap: (SearchResult) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.theme.textSecondary)
                    Text("search.noResultsFound".localized)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                Text("search.results".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .padding(.horizontal, 20)
                
                LazyVStack(spacing: 12) {
                    ForEach(results) { result in
                        SearchResultRow(result: result)
                            .onTapGesture {
                                onTap(result)
                            }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    
    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: result.posterURL, contentMode: .fill)
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 6) {
                Text(result.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Text(result.mediaType == "movie" ? "Movie" : "TV Show")
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                    
                    if let year = result.year {
                        Text("•")
                            .foregroundColor(.theme.textSecondary)
                        Text(year)
                            .font(.system(size: 12))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.theme.accentOrange)
                    Text(result.rating)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                }
                
                if let overview = result.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
