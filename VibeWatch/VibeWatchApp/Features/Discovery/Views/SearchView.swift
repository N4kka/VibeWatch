import SwiftUI

/// Il filtro di tipo della ricerca. Vive nella view: il ranking e la paginazione non devono
/// sapere che esiste, altrimenti una pagina caricata con "Film" attivo tornerebbe monca.
enum SearchScope: String, CaseIterable, Identifiable {
    case all
    case movies
    case series

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "search.scope.all"
        case .movies: return "search.scope.movies"
        case .series: return "search.scope.series"
        }
    }

    func matches(_ mediaType: String) -> Bool {
        switch self {
        case .all: return true
        case .movies: return mediaType == "movie"
        case .series: return mediaType == "tv"
        }
    }
}

struct SearchView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var selectedResult: SearchResult?
    @State private var scope: SearchScope = .all

    private var trimmedQuery: String {
        viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visitedItems: [SearchResult] {
        viewModel.latestVisitedItems.filter { scope.matches($0.mediaType) }
    }

    private var trendingItems: [SearchResult] {
        viewModel.trendingSearches.filter { scope.matches($0.mediaType) }
    }

    private var results: [SearchResult] {
        viewModel.searchResults.filter { scope.matches($0.mediaType) }
    }

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
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .onChange(of: viewModel.searchQuery) {
                        viewModel.search()
                    }

                    scopeChips
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if !visitedItems.isEmpty {
                                LatestVisitedSection(
                                    results: visitedItems,
                                    onClear: { viewModel.clearVisitedItems() },
                                    onTap: { saveAndNavigate(result: $0) }
                                )
                            }

                            if trimmedQuery.isEmpty {
                                TrendingSearchesSection(
                                    results: trendingItems,
                                    onTap: { saveAndNavigate(result: $0) }
                                )
                            } else {
                                SearchResultsSection(
                                    results: results,
                                    query: trimmedQuery,
                                    isLoading: viewModel.isLoading,
                                    isLoadingMore: viewModel.isLoadingMore,
                                    error: viewModel.error,
                                    onTap: { saveAndNavigate(result: $0) },
                                    onItemAppear: handleItemAppear
                                )
                            }
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 24)
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
            AnalyticsService.shared.logScreenView(screenName: "Search")
            isSearchFocused = true
            Task { await viewModel.loadLatestVisitedItems() }
        }
    }

    private var scopeChips: some View {
        HStack(spacing: 10) {
            ForEach(SearchScope.allCases) { item in
                Button {
                    scope = item
                } label: {
                    Text(item.titleKey.localized)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(scope == item ? .black : .theme.textPrimary)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(
                            Capsule().fill(scope == item
                                           ? Color.theme.accentOrange
                                           : Color.white.opacity(0.045))
                        )
                        .overlay(
                            Capsule().stroke(
                                scope == item ? Color.clear : Color.white.opacity(0.14),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// Con un filtro attivo l'ultimo elemento mostrato può stare a metà della lista vera: chi
    /// arriva in fondo a quel che vede deve comunque far scattare la pagina successiva.
    private func handleItemAppear(_ result: SearchResult) {
        if result.id == results.last?.id, let ultimo = viewModel.searchResults.last {
            viewModel.loadMoreIfNeeded(currentItem: ultimo)
        } else {
            viewModel.loadMoreIfNeeded(currentItem: result)
        }
    }

    private func saveAndNavigate(result: SearchResult) {
        viewModel.handleResultTap(result)
        selectedResult = result
    }
}

struct SearchBarView: View {
    @Binding var searchQuery: String
    var isSearchFocused: FocusState<Bool>.Binding
    let onDismiss: () -> Void

    /// Attiva = in scrittura o con del testo: il bordo arancione dice dove sta il fuoco.
    private var isActive: Bool {
        isSearchFocused.wrappedValue || !searchQuery.isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isActive ? .theme.accentOrange : .theme.textSecondary)

                TextField("search.placeholder".localized, text: $searchQuery)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textPrimary)
                    .focused(isSearchFocused)
                    .autocorrectionDisabled()

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(.theme.textPrimary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Capsule().fill(Color.white.opacity(0.065)))
            .overlay(
                Capsule().stroke(
                    isActive ? Color.theme.accentOrange : Color.white.opacity(0.10),
                    lineWidth: isActive ? 1.5 : 1
                )
            )
        }
    }
}

/// L'intestazione di sezione: maiuscoletto spaziato a sinistra, azione o etichetta a destra.
private struct SearchSectionHeader: View {
    let title: String
    var trailing: String?
    var trailingIsAction = false
    var onTrailingTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.4)
                .foregroundColor(.theme.textSecondary)

            Spacer(minLength: 12)

            if let trailing {
                if trailingIsAction, let onTrailingTap {
                    Button(action: onTrailingTap) {
                        Text(trailing)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.theme.accentOrange.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(trailing)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

struct LatestVisitedSection: View {
    let results: [SearchResult]
    let onClear: () -> Void
    let onTap: (SearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SearchSectionHeader(
                title: "search.latestVisited".localized,
                trailing: "search.clear".localized,
                trailingIsAction: true,
                onTrailingTap: onClear
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(results) { result in
                        VisitedPosterCard(result: result)
                            .onTapGesture { onTap(result) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 2)
            }
        }
    }
}

private struct VisitedPosterCard: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: result.posterURL, maxPixelSize: 450)
                .aspectRatio(contentMode: .fill)
                .frame(width: 150, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    Text(MediaKindLabel.text(for: result.mediaType))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(9)
                }

            Text(result.displayTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let year = result.year {
                Text(year)
                    .font(.system(size: 13.5))
                    .foregroundColor(.theme.textSecondary)
            }
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct TrendingSearchesSection: View {
    let results: [SearchResult]
    let onTap: (SearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SearchSectionHeader(
                    title: "search.trendingSearches".localized,
                    trailing: "search.trending.today".localized
                )

                Text(String(format: "search.trending.subtitle".localized,
                            LocalizationManager.shared.currentCountry.name))
                    .font(.system(size: 14.5))
                    .foregroundColor(.theme.textSecondary)
                    .padding(.horizontal, 20)
            }

            LazyVStack(spacing: 12) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    SearchRankedRow(result: result, rank: index + 1)
                        .onTapGesture { onTap(result) }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct SearchResultsSection: View {
    let results: [SearchResult]
    var query: String = ""
    let isLoading: Bool
    var isLoadingMore: Bool = false
    let error: AppError?
    let onTap: (SearchResult) -> Void
    var onItemAppear: (SearchResult) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Results win over the spinner: cached titles are on screen while the remote search is
            // still in flight, so a full-screen ProgressView would hide the very thing it is
            // waiting for. The spinner only stands in when there is nothing at all to show.
            if isLoading && results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if let error = error, results.isEmpty {
                Text(error.errorDescription ?? "An error occurred")
                    .foregroundColor(.theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("search.results".localized.uppercased())
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(1.4)
                            .foregroundColor(.theme.textSecondary)

                        // Keeps the "more is coming" signal without covering what is already there.
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                        }

                        Spacer(minLength: 12)

                        Text(String(format: "search.resultsCount".localized, results.count))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                    }

                    Text(String(format: "search.results.subtitle".localized, query))
                        .font(.system(size: 14.5))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(2)

                    Text("search.mostRelevant".localized.uppercased())
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(1.4)
                        .foregroundColor(.theme.accentOrange)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)

                LazyVStack(spacing: 12) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        SearchRankedRow(result: result, rank: index + 1, query: query)
                            .onTapGesture { onTap(result) }
                            .onAppear { onItemAppear(result) }
                    }

                    if isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

enum MediaKindLabel {
    static func text(for mediaType: String) -> String {
        (mediaType == "movie" ? "common.movie" : "common.tvShow").localized
    }
}

/// La riga numerata di tendenze e risultati: posizione, poster, titolo, meta.
struct SearchRankedRow: View {
    let result: SearchResult
    let rank: Int
    /// Se valorizzata, il prefisso corrispondente è evidenziato dentro il titolo.
    var query: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 19, weight: .heavy))
                .foregroundColor(rank <= 3 ? .theme.accentOrange : .theme.textSecondary)
                .frame(width: 26, alignment: .center)

            CachedAsyncImage(url: result.posterURL, maxPixelSize: 300)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                Text(Self.highlighted(result.displayTitle, query: query))
                    .font(.system(size: 16.5, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    Text(MediaKindLabel.text(for: result.mediaType))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.08)))

                    Text(metaLine)
                        .font(.system(size: 13.5))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.theme.textSecondary.opacity(0.8))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
        )
        .contentShape(Rectangle())
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = result.year { parts.append(year) }
        parts.append("★ \(result.rating)")
        return parts.joined(separator: " · ")
    }

    /// Evidenzia in arancione il tratto di titolo che corrisponde alla query.
    ///
    /// Il confronto passa dalla stessa normalizzazione del ranking, così "sp" accende "Sp" di
    /// "Spider-Man". Se la normalizzazione cambia la lunghezza del testo (può succedere con certe
    /// scritture) gli indici non sono più confrontabili: in quel caso niente evidenziazione,
    /// meglio nessun colore che il colore sulla lettera sbagliata.
    static func highlighted(_ title: String, query: String) -> AttributedString {
        var attributed = AttributedString(title)
        let normalizedQuery = SearchRanking.normalize(query)
        guard !normalizedQuery.isEmpty else { return attributed }

        let normalizedTitle = SearchRanking.normalize(title)
        guard normalizedTitle.count == title.count,
              let match = normalizedTitle.range(of: normalizedQuery)
        else { return attributed }

        let offset = normalizedTitle.distance(from: normalizedTitle.startIndex, to: match.lowerBound)
        let length = normalizedTitle.distance(from: match.lowerBound, to: match.upperBound)

        let characters = attributed.characters
        guard let start = characters.index(
                  characters.startIndex, offsetBy: offset, limitedBy: characters.endIndex
              ),
              let end = characters.index(start, offsetBy: length, limitedBy: characters.endIndex)
        else { return attributed }

        attributed[start..<end].foregroundColor = .theme.accentOrange
        return attributed
    }
}
