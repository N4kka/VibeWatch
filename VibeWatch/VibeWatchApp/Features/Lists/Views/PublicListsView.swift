import SwiftUI

// MARK: - ViewModel

@MainActor
final class PublicListsViewModel: ObservableObject {
    @Published var lists: [PublicList] = []
    @Published var searchText = "" { didSet { onSearchChanged() } }
    @Published var scope: PublicListsScope = .explore { didSet { if oldValue != scope { Task { await reload() } } } }
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let repository: PublicListsProviding
    private let listManager: ListManager
    private let pageSize = 20
    private var canLoadMore = true
    private var searchTask: Task<Void, Never>?

    init(repository: PublicListsProviding? = nil, listManager: ListManager = .shared) {
        self.repository = repository ?? PublicListsRepository()
        self.listManager = listManager
    }

    private func onSearchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // debounce
            guard let self, !Task.isCancelled else { return }
            await self.reload()
        }
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        canLoadMore = true
        do {
            let result = try await repository.fetchPublicLists(search: searchText, scope: scope, limit: pageSize, offset: 0)
            lists = result
            canLoadMore = result.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: PublicList) async {
        guard canLoadMore, !isLoading, current.id == lists.last?.id else { return }
        isLoading = true
        do {
            let next = try await repository.fetchPublicLists(search: searchText, scope: scope, limit: pageSize, offset: lists.count)
            let existing = Set(lists.map(\.id))
            lists.append(contentsOf: next.filter { !existing.contains($0.id) })
            canLoadMore = next.count == pageSize
        } catch { /* feed parziale: silenzioso, retry allo scroll successivo */ }
        isLoading = false
    }

    func toggleFollow(_ list: PublicList) async {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        let wasFollowing = lists[idx].isFollowing
        lists[idx].isFollowing.toggle() // optimistic
        do {
            if wasFollowing {
                try await listManager.unfollowList(listId: list.id)
                if scope == .followed { lists.removeAll { $0.id == list.id } }
            } else {
                try await listManager.followList(listId: list.id)
            }
        } catch {
            if let i = lists.firstIndex(where: { $0.id == list.id }) { lists[i].isFollowing = wasFollowing }
        }
    }
}

// MARK: - Feed

/// Il profilo dell'autore da aprire: wrapper Identifiable per `navigationDestination(item:)`.
/// La destinazione è la stessa di UserSearchView/MainTabView — `PublicProfileView(username:)`.
struct PublicListOwnerTarget: Identifiable, Hashable {
    let username: String
    var id: String { username }
}

struct PublicListsView: View {
    @StateObject private var viewModel = PublicListsViewModel()
    @State private var ownerTarget: PublicListOwnerTarget?

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            SegmentedPicker(
                items: PublicListsScope.allCases,
                selection: $viewModel.scope,
                label: { $0.localizationKey.localized }
            )
            .padding(.bottom, 16)

            if viewModel.isLoading && viewModel.lists.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.lists.isEmpty {
                emptyState
            } else {
                feed
            }
        }
        .task {
            if viewModel.lists.isEmpty { await viewModel.reload() }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.theme.textSecondary)
            TextField("lists.public.searchPlaceholder".localized, text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.lists) { list in
                    NavigationLink(destination: PublicListDetailView(list: list)) {
                        PublicListCard(
                            list: list,
                            onToggleFollow: { Task { await viewModel.toggleFollow(list) } },
                            onOpenOwner: {
                                // Il tap sull'autore apre il suo profilo, non il dettaglio
                                // della lista: la riga è un Button dentro il label del link,
                                // come il pulsante Segui, e intercetta il tocco allo stesso modo.
                                guard let username = list.ownerUsername else { return }
                                ownerTarget = PublicListOwnerTarget(username: username)
                            }
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .task { await viewModel.loadMoreIfNeeded(current: list) }
                }

                if viewModel.isLoading && !viewModel.lists.isEmpty {
                    ProgressView().padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .navigationDestination(item: $ownerTarget) { target in
            PublicProfileView(username: target.username)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.scope == .followed ? "bookmark" : "globe")
                .font(.system(size: 56))
                .foregroundColor(.theme.textSecondary)
            Text((viewModel.scope == .followed ? "lists.public.empty.followed" : "lists.public.empty.explore").localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

struct PublicListCard: View {
    let list: PublicList
    let onToggleFollow: () -> Void
    /// Tap sulla riga autore. Opzionale: dove non è cablato (o l'owner è privato e i campi
    /// arrivano null) la card resta anonima com'era.
    var onOpenOwner: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            cover
                .frame(width: 96, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                // L'autore sopra il nome, come firma della lista: piccolo apposta, il
                // contenuto resta il protagonista della card.
                if let username = list.ownerUsername {
                    PublicListOwnerRow(
                        username: username,
                        avatarUrl: list.ownerAvatarUrl,
                        onTap: onOpenOwner
                    )
                }

                Text(list.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)

                Text("\(list.itemCount) \("common.items".localized)")
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)

                if let description = list.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }

                Spacer(minLength: 4)

                Button(action: onToggleFollow) {
                    HStack(spacing: 6) {
                        Image(systemName: list.isFollowing ? "checkmark" : "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text((list.isFollowing ? "lists.public.following" : "lists.public.follow").localized)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(list.isFollowing ? .theme.textPrimary : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(list.isFollowing ? Color.white.opacity(0.12) : Color.theme.accentOrange)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var cover: some View {
        let paths = list.coverPosterPaths
        if paths.isEmpty {
            Rectangle()
                .fill(Color.theme.backgroundDark.opacity(0.5))
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 30))
                        .foregroundColor(.theme.textSecondary)
                }
        } else if paths.count < 4 {
            poster(paths[0])
        } else {
            // Griglia 2x2 con i primi 4 poster (più recenti).
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                ForEach(Array(paths.prefix(4).enumerated()), id: \.offset) { _, path in
                    poster(path).frame(height: 71)
                }
            }
        }
    }

    @ViewBuilder
    private func poster(_ path: String) -> some View {
        if let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
            CachedAsyncImage(url: url, maxPixelSize: 400) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
            }
        } else {
            Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
        }
    }
}

// MARK: - Riga autore

/// Avatar tondo (24) + @username: la stessa riga sulla card del feed e nell'header del
/// dettaglio, così l'autore ha una faccia sola ovunque. Con `onTap` è un Button; senza,
/// solo testo (il dettaglio la incapsula in un NavigationLink suo).
struct PublicListOwnerRow: View {
    let username: String
    let avatarUrl: String?
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { label }
                .buttonStyle(PlainButtonStyle())
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 7) {
            avatar
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

            Text("@\(username)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarUrl, let url = URL(string: avatarUrl) {
            CachedAsyncImage(url: url, maxPixelSize: 96) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarPlaceholder
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Image(systemName: "person.fill")
                .font(.system(size: 11))
                .foregroundColor(.theme.textSecondary)
        }
    }
}

// MARK: - Detail (read-only)

struct PublicListDetailView: View {
    let list: PublicList

    @StateObject private var availabilityService = ListAvailabilityService.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MediaListItem] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var searchText = ""
    @State private var showInlineSearch = false
    @FocusState private var searchFieldFocused: Bool
    @State private var filters = GlobalDiscoveryFilters()
    @State private var showFilters = false
    @State private var filterRefreshTrigger = false
    @State private var itemsLimit = 100
    @State private var isFollowing: Bool
    @State private var showReportConfirm = false
    @State private var showBlockConfirm = false

    init(list: PublicList) {
        self.list = list
        _isFollowing = State(initialValue: list.isFollowing)
    }

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

    private var filteredItems: [MediaListItem] {
        ListItemFilterer.filteredAndSorted(
            items,
            searchText: searchText,
            filters: filters,
            availabilityByItemId: availabilityService.availableItems,
            applyReleasePeriodFilter: true
        )
    }

    var body: some View {
        let visible = filteredItems
        let paginated = Array(visible.prefix(itemsLimit))
        return ZStack(alignment: .top) {
            Color.theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // L'autore nell'header del dettaglio, quando il suo profilo è pubblico: il
                // titolo grande resta il nome della lista, la firma sta subito sotto e porta
                // al profilo (stessa destinazione della card del feed).
                if let username = list.ownerUsername {
                    NavigationLink(destination: PublicProfileView(username: username)) {
                        PublicListOwnerRow(username: username, avatarUrl: list.ownerAvatarUrl)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }

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

                content(visible: visible, paginated: paginated)
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if showFilters {
                GlobalFilterView(filters: $filters, isPresented: $showFilters, onApply: { _ in filterRefreshTrigger.toggle() })
                    .environmentObject(quotaManager)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { Task { await toggleFollow() } } label: {
                    Image(systemName: isFollowing ? "bookmark.fill" : "bookmark")
                }
                // M3 — anche una lista altrui si condivide, e la card porta la firma del suo
                // autore: chi la vede deve sapere di chi è la lista, non di chi l'ha girata.
                ListShareButton(source: .init(publicList: list))
                Menu {
                    Button(role: .destructive) { showReportConfirm = true } label: {
                        Label("lists.public.report".localized, systemImage: "flag")
                    }
                    Button(role: .destructive) { showBlockConfirm = true } label: {
                        Label("lists.public.block".localized, systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("lists.public.report.confirm".localized, isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("lists.public.report".localized, role: .destructive) { Task { await reportList() } }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .confirmationDialog("lists.public.block.confirm".localized, isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("lists.public.block".localized, role: .destructive) { Task { await blockOwner() } }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .task {
            AnalyticsService.shared.track(.communityListOpened(listId: list.id))
            await loadItems()
        }
        .onChange(of: filters) { _, _ in itemsLimit = 100 }
        .onChange(of: searchText) { _, _ in itemsLimit = 100 }
    }

    @ViewBuilder
    private func content(visible: [MediaListItem], paginated: [MediaListItem]) -> some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed || (items.isEmpty && list.itemCount > 0) {
            unavailableState
        } else if visible.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "list.bullet").font(.system(size: 60)).foregroundColor(.theme.textSecondary)
                Text("lists.noItems".localized).font(.system(size: 16)).foregroundColor(.theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(paginated) { item in
                        MediaItemRow(item: item, isInSeenList: false, onMarkAsSeen: {}, onDelete: {}, isReadOnly: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }
            .overlay(alignment: .bottom) {
                if visible.count > paginated.count {
                    Button { itemsLimit += 100 } label: {
                        Text("common.loadMore".localized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32).padding(.vertical, 12)
                            .background(Color.theme.accentOrange)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 24)
                }
            }
            .id(filterRefreshTrigger)
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash").font(.system(size: 56)).foregroundColor(.theme.textSecondary)
            Text("lists.public.unavailable".localized)
                .font(.system(size: 16)).foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.theme.textSecondary)
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

    private func loadItems() async {
        isLoading = true
        loadFailed = false
        do {
            items = try await SupabaseService.shared.fetchListItems(listId: list.id)
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    private func toggleFollow() async {
        let was = isFollowing
        isFollowing.toggle()
        do {
            if was { try await ListManager.shared.unfollowList(listId: list.id) }
            else { try await ListManager.shared.followList(listId: list.id) }
        } catch {
            isFollowing = was
        }
    }

    private func reportList() async {
        try? await ListManager.shared.reportList(listId: list.id)
        showBanner("lists.public.report.done".localized)
    }

    private func blockOwner() async {
        do {
            try await SupabaseService.shared.blockListOwner(listId: list.id)
            await MainActor.run { dismiss() }
        } catch {
            ToastCenter.shared.show(error: "common.error".localized)
        }
    }

    private func showBanner(_ text: String) {
        ToastCenter.shared.show(success: text)
    }
}
