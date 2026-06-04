import Foundation
import Combine

enum ListError: LocalizedError, Equatable {
    case maxListsReached(limit: Int)
    case maxItemsReached(limit: Int)
    case listNotFound
    case itemAlreadyInList
    case defaultListImmutable
    case invalidName
    case authenticationRequired
    
    var errorDescription: String? {
        switch self {
        case .maxListsReached(let limit):
            return "lists.error.maxListsReached".localizedMainSafe().replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .maxItemsReached(let limit):
            return "lists.error.maxItemsReached".localizedMainSafe().replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .listNotFound:
            return "lists.error.listNotFound".localizedMainSafe()
        case .itemAlreadyInList:
            return "lists.error.itemAlreadyInList".localizedMainSafe()
        case .defaultListImmutable:
            return "lists.error.defaultImmutable".localizedMainSafe()
        case .invalidName:
            return "lists.error.invalidName".localizedMainSafe()
        case .authenticationRequired:
            return "lists.error.authRequired".localizedMainSafe()
        }
    }
}

@MainActor
class ListManager: ObservableObject {
    static let shared = ListManager()
    
    // Limits
    static let proMaxCustomLists = 100
    static let freeMaxCustomLists = 2
    static let maxItemsPerList = 1000
    static let softLimitWarningThreshold = 500
    
    @Published var lists: [MediaList] = []
    @Published var watchlist: MediaList
    @Published var seenList: MediaList
    @Published var likedList: MediaList
    @Published var dislikedList: MediaList
    @Published var softLimitWarningMessage: String?
    @Published var isLoadingInitial = true
    
    private let db: SQLiteService
    private let sync: SyncEngineProtocol
    private let supabase: ListsRemoteDataSource
    private let authService: AuthStatusProviding
    private var cancellables = Set<AnyCancellable>()
    private var userId: String {
        authService.currentUser?.id ?? getDeviceId()
    }

    var currentCustomListLimit: Int {
        EntitlementPolicy.maxCustomLists(for: DailyQuotaManager.shared.isProUser ? .pro : .free)
    }

    /// Designated initializer with injectable dependencies (test enabler).
    /// Production keeps using `.shared` with the singleton defaults; tests can pass a
    /// SQLiteService backed by a temp DB plus mocks, and set `autoStart: false` to avoid
    /// triggering the initial load and the auth/locale observers.
    init(
        db: SQLiteService = .shared,
        sync: SyncEngineProtocol = SyncEngine.shared,
        supabase: ListsRemoteDataSource = SupabaseService.shared,
        authService: AuthStatusProviding = AuthService.shared,
        autoStart: Bool = true
    ) {
        self.db = db
        self.sync = sync
        self.supabase = supabase
        self.authService = authService

        // Initialize default lists with stable type-keyed names
        self.watchlist = MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        self.seenList = MediaList(name: ListType.seen.rawValue, type: .seen)
        self.likedList = MediaList(name: ListType.liked.rawValue, type: .liked)
        self.dislikedList = MediaList(name: ListType.disliked.rawValue, type: .disliked)
        self.softLimitWarningMessage = nil

        guard autoStart else { return }

        loadLists()

        // Observe authentication state changes
        authService.isAuthenticatedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthenticated in
                guard let self = self else { return }
                Task {
                    if isAuthenticated {
                        await self.syncListsForAuthenticatedUser()
                    } else {
                        self.resetListsForLoggedOutUser()
                    }
                }
            }
            .store(in: &cancellables)

        // Re-publish when language changes so views re-render with updated displayName
        LocalizationManager.shared.$localeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    
    // Call this when user logs in
    func syncListsForAuthenticatedUser() async {
        guard let authenticatedUserId = authService.currentUser?.id else {
            Logger.warning("[ListManager] Not authenticated, cannot sync remote lists.")
            return
        }

        Logger.info("[ListManager] Syncing lists for authenticated user: \(authenticatedUserId.prefix(8))...")
        
        do {
            // 0. Flush any locally-queued changes (adds/removes/moves) to Supabase BEFORE
            //    pulling remote state. Otherwise a pull can clobber local edits that haven't
            //    synced yet — e.g. a "mark as seen" done just before relaunch would be
            //    overwritten by stale remote rows and appear to revert to the watchlist.
            await sync.pushPendingChanges()

            // 1. Fetch remote lists for the authenticated user
            var remoteLists = try await supabase.fetchLists()
            Logger.info("[ListManager] Fetched \(remoteLists.count) remote lists from Supabase.")
            
            // 2. Load current local lists (which might still contain anonymous lists)
            let localListsBeforeSync = lists
            
            // 3. Merge/Prioritize: Remote lists become the primary source.
            //    Ensure core lists are present in remote lists
            remoteLists = ensureCoreLists(in: remoteLists)
            
            // 4. Handle custom local lists that might not be on Supabase yet
            //    These are lists created by the user when they were anonymous on this device.
            //    Single remote writer (4.3): l'upload va via outbox/SyncEngine, NON più con
            //    N chiamate dirette supabase.createList + supabase.addItemToList (burst N+1 al
            //    login). Accodiamo lista + item sull'outbox (persistendoli anche localmente) e
            //    li flushiamo in coda con UNA singola apply_mutations batch.
            var didEnqueueLocalUploads = false
            for localList in localListsBeforeSync where localList.type == .custom {
                guard !remoteLists.contains(where: { $0.id == localList.id }) else { continue }

                await ensureListInSQLite(localList)
                let now = ISO8601DateFormatter().string(from: Date())
                try await sync.queueOperation(
                    table: "lists",
                    operationType: "INSERT",
                    recordId: localList.id,
                    payload: [
                        "id": localList.id,
                        "user_id": authenticatedUserId,
                        "name": localList.name,
                        "description": localList.description ?? "",
                        "type": ListType.custom.rawValue,
                        "created_at": ISO8601DateFormatter().string(from: localList.createdAt),
                        "updated_at": now
                    ],
                    dependsOn: nil
                )

                // addItemToSQLite persiste in SQLite E accoda INSERT list_items sull'outbox.
                for item in localList.items {
                    await addItemToSQLite(item, listId: localList.id)
                }

                remoteLists.append(localList) // Add to our working set of lists
                didEnqueueLocalUploads = true
                Logger.info("[ListManager] Queued local custom list '\(localList.name)' (\(localList.items.count) items) for remote sync.")
            }

            // 5. Update local state with the merged lists
            applyLists(remoteLists)
            await saveListsToSQLite()

            // 6. Flush subito le liste locali-only appena accodate, così restano "caricate al
            //    login" come prima — ma in UNA apply_mutations batch invece del vecchio N+1.
            if didEnqueueLocalUploads {
                await sync.pushPendingChanges()
            }

            Logger.info("[ListManager] Lists synced successfully for authenticated user.")
            
        } catch {
            Logger.error("[ListManager] Error syncing lists for authenticated user: \(error)")
            // If fetching remote lists fails, perhaps revert to local only or show error
            // For now, we'll just log and keep whatever local state was there
        }
    }
    
    // Call this when user logs out
    func resetListsForLoggedOutUser() {
        Logger.info("[ListManager] Resetting lists for logged out user.")
        
        // Clear all lists and revert to empty default lists only
        // This ensures no authenticated user data remains visible
        let emptyWatchlist = MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        let emptySeenList = MediaList(name: ListType.seen.rawValue, type: .seen)
        let emptyLikedList = MediaList(name: ListType.liked.rawValue, type: .liked)
        let emptyDislikedList = MediaList(name: ListType.disliked.rawValue, type: .disliked)
        
        // Set lists to only empty default lists
        self.lists = [emptyWatchlist, emptySeenList, emptyLikedList, emptyDislikedList]
        self.watchlist = emptyWatchlist
        self.seenList = emptySeenList
        self.likedList = emptyLikedList
        self.dislikedList = emptyDislikedList
        
        // Save the empty state to SQLite
        Task { await saveListsToSQLite() }

        Logger.info("[ListManager] Lists cleared for logged out user - showing empty defaults only.")
    }
    
    func loadLists() {
        // Load from SQLite ONLY (single source of truth)
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadListsFromSQLite()
            isLoadingInitial = false
            await ensureListsInDatabase()
        }
    }

    /// One-time migration: import lists from UserDefaults to SQLite, then delete the key
    private func migrateFromUserDefaultsIfNeeded() async {
        let userDefaultsKey = "media_lists"
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([MediaList].self, from: data) else {
            return
        }

        Logger.info("[ListManager] Migrating \(decoded.count) lists from UserDefaults to SQLite...")
        for list in decoded {
            await ensureListInSQLite(list)
            for item in list.items {
                await addItemToSQLite(item, listId: list.id)
            }
        }

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        Logger.info("[ListManager] Migration complete. Removed UserDefaults key '\(userDefaultsKey)'")
    }

    /// Load lists from SQLite (single source of truth)
    /// Internal (not private) so the full-set load invariant can be characterized in tests.
    func loadListsFromSQLite() async {
        let currentUserId = authService.currentUser?.id ?? getDeviceId()

        do {
            let listsQuery = """
                SELECT l.id, l.name, l.description, l.type, l.created_at
                FROM lists l
                WHERE l.user_id = ? AND l.deleted_at IS NULL
                ORDER BY l.created_at DESC
            """
            let listRows = try await db.queryRaw(listsQuery, parameters: [currentUserId])

            guard !listRows.isEmpty else {
                // No lists in SQLite - initialize with defaults
                self.lists = [watchlist, seenList, likedList, dislikedList]
                Logger.info("[ListManager] No lists in SQLite. Initialized defaults.")
                return
            }

            let listIds = listRows.compactMap { $0["id"] as? String }
            let placeholders = listIds.map { _ in "?" }.joined(separator: ", ")
            let itemsQuery = """
                SELECT * FROM list_items
                WHERE list_id IN (\(placeholders)) AND deleted_at IS NULL
                ORDER BY added_at DESC
            """
            let itemRows = try await db.queryRaw(itemsQuery, parameters: listIds)

            var itemsByListId: [String: [MediaListItem]] = [:]
            for row in itemRows {
                guard let listId = row["list_id"] as? String,
                      let item = MediaListItem.from(dictionary: row) else { continue }
                itemsByListId[listId, default: []].append(item)
            }

            var loadedLists: [MediaList] = []
            for row in listRows {
                guard let id = row["id"] as? String,
                      let name = row["name"] as? String,
                      let typeRaw = row["type"] as? String,
                      let type = ListType(rawValue: typeRaw) else { continue }

                let items = itemsByListId[id] ?? []
                let list = MediaList(
                    id: id,
                    name: name,
                    description: row["description"] as? String,
                    type: type,
                    createdAt: ISO8601DateFormatter().date(from: row["created_at"] as? String ?? "") ?? Date(),
                    items: items
                )
                loadedLists.append(list)
            }

            applyLists(loadedLists)
            Logger.info("[ListManager] Loaded \(loadedLists.count) lists with \(itemRows.count) items from SQLite")
        } catch {
            Logger.error("[ListManager] Failed to load from SQLite: \(error)")
            // Initialize with defaults rather than failing silently
            self.lists = [watchlist, seenList, likedList, dislikedList]
        }
    }
    
    /// Ensure all in-memory lists exist in both SQLite and Supabase.
    ///
    /// 4.3b — taglio dell'N+1 a ogni avvio: prima questo metodo faceva `supabase.createList`
    /// DIRETTO per OGNI lista a ogni cold launch (4+ round-trip per lo più falliti per conflitto
    /// PK). Ora:
    ///  - lo facciamo SOLO per le liste non ancora riconciliate col remoto (`synced_at IS NULL`):
    ///    per gli utenti esistenti (liste già pull-ate) il costo remoto al lancio è ZERO.
    ///  - liste di DEFAULT (non cancellabili) → via outbox/SyncEngine (single remote writer 4.2);
    ///    `apply_mutations` fa un upsert idempotente e, non potendo essere soft-deleted, non c'è
    ///    rischio di "resurrection".
    ///  - liste CUSTOM → restano sul `createList` DIRETTO insert-or-fail. È deliberato: le custom
    ///    SONO cancellabili e `apply_mutations` su `lists` è un upsert → un INSERT via outbox
    ///    potrebbe riportare in vita una custom soft-deleted su un altro device (famiglia 141→1).
    ///    L'insert-or-fail (fallisce su riga esistente) preserva la non-resurrection.
    func ensureListsInDatabase() async {
        // First, ensure device profile exists in SQLite (for foreign key constraint)
        await ensureDeviceProfileInSQLite()

        for list in lists {
            // Ensure in SQLite
            await ensureListInSQLite(list)
        }

        guard authService.currentUser != nil else { return }

        for list in lists {
            // Salta le liste già riconciliate col remoto: niente più burst a ogni avvio.
            guard await listNeedsRemoteEnsure(list.id) else { continue }

            if list.type == .custom {
                // Custom: createList diretto insert-or-fail (no resurrection, vedi doc sopra).
                do {
                    _ = try await supabase.createList(id: list.id, name: list.name, description: list.description, type: list.type)
                    Logger.debug("[ListManager] Ensured custom list '\(list.name)' exists in Supabase")
                } catch {
                    // List might already exist, which is fine
                    Logger.debug("[ListManager] Custom list '\(list.name)' may already exist in Supabase: \(error)")
                }
            } else {
                // Default: via outbox (single remote writer).
                let now = ISO8601DateFormatter().string(from: Date())
                try? await sync.queueOperation(
                    table: "lists",
                    operationType: "INSERT",
                    recordId: list.id,
                    payload: [
                        "id": list.id,
                        "user_id": userId,
                        "name": list.name,
                        "description": list.description ?? "",
                        "type": list.type.rawValue,
                        "created_at": ISO8601DateFormatter().string(from: list.createdAt),
                        "updated_at": now
                    ],
                    dependsOn: nil
                )
                Logger.debug("[ListManager] Queued default list '\(list.name)' for remote ensure")
            }
        }
    }

    /// True se la lista locale non risulta ancora riconciliata col remoto (`synced_at IS NULL`),
    /// quindi va garantita lato server. Il pull remoto popola `synced_at` (vedi SQLiteService.upsert).
    private func listNeedsRemoteEnsure(_ id: String) async -> Bool {
        let rows = (try? await db.queryRaw(
            "SELECT synced_at FROM lists WHERE id = ?",
            parameters: [id]
        )) ?? []
        guard let row = rows.first else { return true }
        return (row["synced_at"] as? String) == nil
    }
    
    /// Ensure device profile exists in SQLite (required for foreign key constraint)
    private func ensureDeviceProfileInSQLite() async {
        let success = db.execute("""
            INSERT OR IGNORE INTO profiles (id, email, display_name, avatar_url, created_at, updated_at)
            VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
        """, parameters: [
            userId,
            "device@local",
            "Local User",
            nil as String? as Any
        ])
        
        if success {
            Logger.debug("[ListManager] Ensured device profile exists in SQLite")
        } else {
            Logger.warning("[ListManager] Failed to ensure device profile in SQLite")
        }
    }
    
    private func ensureListInSQLite(_ list: MediaList) async {
        let success = db.execute("""
            INSERT OR IGNORE INTO lists (id, name, description, type, created_at, user_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, parameters: [
            list.id,
            list.name,
            list.description ?? "",
            list.type.rawValue,
            ISO8601DateFormatter().string(from: list.createdAt),
            userId
        ])
        
        if success {
            Logger.debug("[ListManager] Ensured list '\(list.name)' exists in SQLite")
        } else {
            Logger.warning("[ListManager] Failed to ensure list '\(list.name)' in SQLite")
        }
    }

    private func applyLists(_ source: [MediaList]) {
        let merged = ensureCoreLists(in: source)
        self.lists = merged
        updateDefaultReferences(from: merged)
    }
    
    private func ensureCoreLists(in source: [MediaList]) -> [MediaList] {
        var finalLists = source
        for type in [ListType.watchlist, .seen, .liked, .disliked] {
            if !finalLists.contains(where: { $0.type == type }) {
                finalLists.insert(defaultList(for: type), at: 0)
            }
        }
        return finalLists
    }
    
    private func updateDefaultReferences(from lists: [MediaList]) {
        if let watchlist = lists.first(where: { $0.type == .watchlist }) {
            self.watchlist = watchlist
        }
        if let seen = lists.first(where: { $0.type == .seen }) {
            self.seenList = seen
        }
        if let liked = lists.first(where: { $0.type == .liked }) {
            self.likedList = liked
        }
        if let disliked = lists.first(where: { $0.type == .disliked }) {
            self.dislikedList = disliked
        }
    }
    
    private func defaultList(for type: ListType) -> MediaList {
        switch type {
        case .watchlist: return MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        case .seen: return MediaList(name: ListType.seen.rawValue, type: .seen)
        case .liked: return MediaList(name: ListType.liked.rawValue, type: .liked)
        case .disliked: return MediaList(name: ListType.disliked.rawValue, type: .disliked)
        case .custom: return MediaList(name: "custom", type: .custom)
        }
    }
    
    /// Save all current lists (metadata + items) to SQLite
    private func saveListsToSQLite() async {
        for list in lists {
            await ensureListInSQLite(list)
            if !list.items.isEmpty {
                await saveItemsToSQLite(list.items, listId: list.id)
            }
        }
    }

    /// Batch-upsert items using INSERT OR IGNORE so synced items survive the next cold launch
    private func saveItemsToSQLite(_ items: [MediaListItem], listId: String) async {
        let records: [[String: Any]] = items.map { item in [
            "id": item.id,
            "list_id": listId,
            "user_id": userId,
            "media_id": item.mediaId,
            "media_type": item.mediaType.rawValue,
            "title": item.title,
            "poster_path": item.posterPath ?? "",
            "runtime": item.runtime as Any,
            "vote_average": item.voteAverage as Any,
            "vote_count": item.voteCount as Any,
            "origin_country": stringArray(item.originCountry),
            "release_date": item.releaseDate ?? "",
            "genres": intArray(item.genres),
            "overview": item.overview ?? "",
            "added_at": ISO8601DateFormatter().string(from: item.addedAt)
        ]}
        await db.performBatchInsert(table: "list_items", records: records)
    }

    @discardableResult
    func fetchLists() async throws -> [MediaList] {
        guard authService.currentUser != nil else {
            loadLists()
            return lists
        }
        let remoteLists = try await supabase.fetchLists()
        applyLists(remoteLists)
        await saveListsToSQLite()
        return remoteLists
    }
    
    @discardableResult
    func createList(name: String, description: String? = nil) async throws -> MediaList {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ListError.invalidName
        }
        guard canCreateList() else {
            throw ListError.maxListsReached(limit: currentCustomListLimit)
        }
        
        guard authService.currentUser != nil else {
            throw ListError.authenticationRequired
        }
        
        // Offline-first: genera l'ID e costruisci la lista LOCALMENTE (prima era remote-first:
        // se offline la creazione falliva del tutto).
        let listId = UUID().uuidString
        let newList = MediaList(
            id: listId,
            name: trimmedName,
            description: description,
            type: .custom,
            createdAt: Date(),
            items: []
        )

        lists.append(newList)
        await ensureListInSQLite(newList)

        // Single remote writer (4.2): la creazione remota va via outbox/SyncEngine
        // (apply_mutations gestisce l'INSERT su `lists`), non più diretta a Supabase.
        let now = ISO8601DateFormatter().string(from: Date())
        try await sync.queueOperation(
            table: "lists",
            operationType: "INSERT",
            recordId: listId,
            payload: [
                "id": listId,
                "user_id": userId,
                "name": trimmedName,
                "description": description ?? "",
                "type": ListType.custom.rawValue,
                "created_at": now,
                "updated_at": now
            ],
            dependsOn: nil
        )

        // Analytics: Track list creation
        AnalyticsService.shared.logListCreated(listType: "custom", listName: trimmedName)
        
        return newList
    }
    
    func updateList(id: String, name: String, description: String? = nil) async throws {
        guard let index = lists.firstIndex(where: { $0.id == id }) else {
            throw ListError.listNotFound
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ListError.invalidName
        }
        let existing = lists[index]
        let updated = MediaList(
            id: existing.id,
            name: trimmedName,
            description: description,
            type: existing.type,
            createdAt: existing.createdAt,
            items: existing.items
        )
        lists[index] = updated
        updateDefaultReferences(from: lists)
        notifySoftLimitIfNeeded(for: lists[index])

        // Local-first: ensureListInSQLite usa INSERT OR IGNORE → per un update serve una
        // UPDATE esplicita, altrimenti il nuovo nome non viene persistito localmente.
        _ = db.execute(
            "UPDATE lists SET name = ?, description = ?, updated_at = datetime('now') WHERE id = ?",
            parameters: [trimmedName, description ?? "", id]
        )

        // Single remote writer (4.2): propaga via outbox/SyncEngine, non più diretto a Supabase.
        try await sync.queueOperation(
            table: "lists",
            operationType: "UPDATE",
            recordId: id,
            payload: [
                "id": id,
                "user_id": userId,
                "name": trimmedName,
                "description": description ?? "",
                "type": existing.type.rawValue,
                "created_at": ISO8601DateFormatter().string(from: existing.createdAt),
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ],
            dependsOn: nil
        )
    }
    
    func deleteList(id: String) async throws {
        guard let index = lists.firstIndex(where: { $0.id == id }) else {
            throw ListError.listNotFound
        }
        guard lists[index].type == .custom else {
            throw ListError.defaultListImmutable
        }
        let listType = lists[index].type.rawValue
        
        lists.remove(at: index)

        // Local-first: soft delete locale (awaited, deterministico).
        let success = db.execute(
            "UPDATE lists SET deleted_at = datetime('now') WHERE id = ?",
            parameters: [id]
        )
        if !success {
            Logger.error("[ListManager] Failed to soft-delete list \(id) from SQLite")
        }

        // Single remote writer (4.2): la cancellazione remota va via outbox/SyncEngine,
        // non più diretta a Supabase. apply_mutations fa il soft-delete owner-scoped.
        try await sync.queueOperation(
            table: "lists",
            operationType: "DELETE",
            recordId: id,
            payload: ["id": id, "user_id": userId],
            dependsOn: nil
        )

        // Analytics: Track list deletion
        AnalyticsService.shared.logListDeleted(listType: listType)
    }
    
    func canCreateList() -> Bool {
        let customListCount = lists.filter { $0.type == .custom }.count
        return customListCount < currentCustomListLimit
    }
    
    func customListsCount() -> Int {
        lists.filter { $0.type == .custom }.count
    }
    
    func addToList(
        listId: String,
        movie: Movie,
        mediaType: MediaType,
        analyticsContext: AnalyticsContext? = nil
    ) async throws {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            throw ListError.listNotFound
        }
        
        // Check if user is authenticated for custom lists
        // Anonymous users can only add to watchlist
        if lists[index].type == .custom && authService.currentUser == nil {
            throw ListError.authenticationRequired
        }

        if lists[index].items.contains(where: { $0.mediaId == movie.id && $0.mediaType == mediaType }) {
            throw ListError.itemAlreadyInList
        }

        if lists[index].type == .custom && lists[index].items.count >= Self.maxItemsPerList {
            throw ListError.maxItemsReached(limit: Self.maxItemsPerList)
        }

        let originCountry = movie.productionCountries?.map { $0.iso }
        let genreIds = movie.genreIds ?? movie.genres?.map { $0.id }
        let item = MediaListItem(
            mediaId: movie.id,
            mediaType: mediaType,
            title: movie.title,
            posterPath: movie.posterPath,
            runtime: movie.runtime,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            originCountry: originCountry,
            releaseDate: movie.releaseDate,
            genres: genreIds,
            overview: movie.overview
        )

        // Always save locally first
        objectWillChange.send()
        lists[index].items.append(item)
        
        // Single remote writer (4.2): la sincronizzazione remota avviene SOLO via
        // outbox/SyncEngine (vedi addItemToSQLite → queueOperation). Rimossa la scrittura
        // diretta a Supabase (dual-write) che causava id-divergence tra i due path.

        // Also save to local SQLite for offline access.
        // Awaited (non più fire-and-forget) così la persistenza locale e l'enqueue
        // sull'outbox completano prima del ritorno → comportamento deterministico/testabile.
        // L'append in-memory è già avvenuto sopra, quindi la UI resta reattiva.
        await addItemToSQLite(item, listId: listId)

        updateDefaultReferences(from: lists)
        notifySoftLimitIfNeeded(for: lists[index])
        // Item already saved to SQLite via addItemToSQLite above

        // Analytics: Track item added
        AnalyticsService.shared.logItemAddedToList(
            listType: lists[index].type.rawValue,
            mediaType: mediaType.rawValue,
            context: analyticsContext
        )

        PaywallTriggerService.shared.recordSavedToList()
        
        // Prompt for a review after a successful save action (gated by heuristics)
        ReviewPromptManager.shared.recordPositiveAction()
        
        // Prefetch image for offline viewing (watchlist only, WiFi only)
        if lists[index].type == .watchlist, let posterPath = item.posterPath {
            Task.detached(priority: .utility) {
                let imageURL = "https://image.tmdb.org/t/p/w500\(posterPath)"
                await ImageCacheService.shared.prefetchImages([imageURL], onWiFiOnly: true)
            }
        }
    }
    
    func canAddToList(listId: String) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        if list.type == .custom {
            return list.items.count < Self.maxItemsPerList
        }
        return true // No limit for default lists
    }

    func getItems(listId: String) async throws -> [MediaListItem] {
        if supabase.currentUser != nil {
            let items = try await supabase.fetchListItems(listId: listId)
            if let index = lists.firstIndex(where: { $0.id == listId }) {
                lists[index].items = items
                updateDefaultReferences(from: lists)
            }
            return items
        }
        return lists.first(where: { $0.id == listId })?.items ?? []
    }

    private func notifySoftLimitIfNeeded(for list: MediaList) {
        guard list.type == .custom else { return }
        if list.items.count == Self.softLimitWarningThreshold {
            let message = "lists.softLimitWarning".localized
                .replacingOccurrences(of: "{name}", with: list.name)
                .replacingOccurrences(of: "{limit}", with: "\(Self.softLimitWarningThreshold)")
            softLimitWarningMessage = message
        }
    }
    
    func removeFromList(listId: String, itemId: String) async throws {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }) else {
            throw ListError.listNotFound
        }

        // Always remove locally first
        objectWillChange.send()
        lists[listIndex].items.removeAll { $0.id == itemId }
        updateDefaultReferences(from: lists)

        // Single remote writer (4.2): la rimozione remota avviene SOLO via outbox/SyncEngine
        // (vedi removeItemFromSQLite → queueOperation DELETE). Rimossa la scrittura diretta.

        // Also remove from local SQLite.
        // Awaited (non più fire-and-forget) così l'enqueue sull'outbox è deterministico/testabile.
        await removeItemFromSQLite(itemId)
    }
    
    private func removeItemFromSQLite(_ itemId: String) async {
        do {
            // Soft delete in local SQLite
            _ = try await db.queryRaw("""
                UPDATE list_items
                SET deleted_at = datetime('now')
                WHERE id = ?
            """, parameters: [itemId])
            
            // Queue for sync
            try await sync.queueOperation(
                table: "list_items",
                operationType: "DELETE",
                recordId: itemId,
                payload: ["id": itemId],
                dependsOn: nil
            )
            
            Logger.debug("[ListManager] Removed item \(itemId) from SQLite and queued for sync")

        } catch {
            Logger.error("[ListManager] Failed to remove item from SQLite: \(error)")
        }
    }
    
    func isInList(listId: String, mediaId: Int, mediaType: MediaType) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        return list.items.contains(where: { $0.mediaId == mediaId && $0.mediaType == mediaType })
    }
    
    private func addItemToSQLite(_ item: MediaListItem, listId: String) async {
        do {
            let values: [String: Any] = [
                "id": item.id,
                "list_id": listId,
                "user_id": userId,
                "media_id": item.mediaId,
                "media_type": item.mediaType.rawValue,
                "title": item.title,
                "poster_path": item.posterPath ?? "",
                "runtime": item.runtime as Any,
                "vote_average": item.voteAverage as Any,
                "vote_count": item.voteCount as Any,
                "origin_country": stringArray(item.originCountry),
                "release_date": item.releaseDate ?? "",
                "genres": intArray(item.genres),
                "overview": item.overview ?? "",
                "added_at": ISO8601DateFormatter().string(from: Date())
            ]
            
            // Insert to local SQLite
            _ = try await db.insert("list_items", values: values)
            
            // Queue for sync
            try await sync.queueOperation(
                table: "list_items",
                operationType: "INSERT",
                recordId: item.id,
                payload: values,
                dependsOn: nil
            )
            
            Logger.debug("[ListManager] Added item '\(item.title)' to SQLite and queued for sync")

        } catch {
            Logger.error("[ListManager] Failed to add item to SQLite: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func getDeviceId() -> String {
        let key = "deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
    
    private func parseStringArray(_ json: String?) -> [String]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return array
    }
    
    private func parseIntArray(_ json: String?) -> [Int]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([Int].self, from: data) else {
            return nil
        }
        return array
    }
    
    private func stringArray(_ array: [String]?) -> String {
        guard let array = array,
              let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
    
    private func intArray(_ array: [Int]?) -> String {
        guard let array = array,
              let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
