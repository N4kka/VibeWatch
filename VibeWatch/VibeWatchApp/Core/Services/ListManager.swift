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
    
    private let db = SQLiteService.shared
    private let sync = SyncWorker.shared
    private let supabase = SupabaseService.shared
    private let authService = AuthService.shared
    private var cancellables = Set<AnyCancellable>()
    private var userId: String {
        authService.currentUser?.id ?? getDeviceId()
    }

    var currentCustomListLimit: Int {
        DailyQuotaManager.shared.isProUser ? Self.proMaxCustomLists : Self.freeMaxCustomLists
    }

    private init() {
        // Initialize default lists
        self.watchlist = MediaList(name: "lists.watchlist".localized, type: .watchlist)
        self.seenList = MediaList(name: "lists.seen".localized, type: .seen)
        self.likedList = MediaList(name: "lists.liked".localized, type: .liked)
        self.dislikedList = MediaList(name: "lists.disliked".localized, type: .disliked)
        self.softLimitWarningMessage = nil

        loadLists()
        
        // Observe authentication state changes
        authService.$isAuthenticated
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
    }
    
    // Call this when user logs in
    func syncListsForAuthenticatedUser() async {
        guard let authenticatedUserId = authService.currentUser?.id else {
            print("⚠️ [ListManager] Not authenticated, cannot sync remote lists.")
            return
        }

        print("🔄 [ListManager] Syncing lists for authenticated user: \(authenticatedUserId)")
        
        do {
            // 1. Fetch remote lists for the authenticated user
            var remoteLists = try await supabase.fetchLists()
            print("✅ [ListManager] Fetched \(remoteLists.count) remote lists from Supabase.")
            
            // 2. Load current local lists (which might still contain anonymous lists)
            let localListsBeforeSync = lists
            
            // 3. Merge/Prioritize: Remote lists become the primary source.
            //    Ensure core lists are present in remote lists
            remoteLists = ensureCoreLists(in: remoteLists)
            
            // 4. Handle custom local lists that might not be on Supabase yet
            //    These are lists created by the user when they were anonymous on this device
            for localList in localListsBeforeSync where localList.type == .custom {
                if !remoteLists.contains(where: { $0.id == localList.id }) {
                    // This custom list exists locally but not remotely. Try to upload it.
                    do {
                        // Create it on Supabase - using the local list's data
                        _ = try await supabase.createList(id: localList.id, name: localList.name, description: localList.description, type: .custom)
                        print("⬆️ [ListManager] Uploaded local custom list '\(localList.name)' to Supabase.")
                        
                        // Upload its items too
                        for item in localList.items {
                            _ = try await supabase.addItemToList(listId: localList.id, item: item)
                            print("⬆️ [ListManager] Uploaded item '\(item.title)' to Supabase for list '\(localList.name)'.")
                        }
                        remoteLists.append(localList) // Add to our working set of lists
                    } catch {
                        print("❌ [ListManager] Failed to upload local custom list '\(localList.name)': \(error)")
                    }
                }
            }
            
            // 5. Update local state with the merged lists
            applyLists(remoteLists)
            saveLists() // Save to UserDefaults (now containing authenticated lists)
            
            print("✅ [ListManager] Lists synced successfully for authenticated user.")
            
        } catch {
            print("❌ [ListManager] Error syncing lists for authenticated user: \(error)")
            // If fetching remote lists fails, perhaps revert to local only or show error
            // For now, we'll just log and keep whatever local state was there
        }
    }
    
    // Call this when user logs out
    func resetListsForLoggedOutUser() {
        print("↩️ [ListManager] Resetting lists for logged out user.")
        
        // Clear all lists and revert to empty default lists only
        // This ensures no authenticated user data remains visible
        let emptyWatchlist = MediaList(name: "lists.watchlist".localized, type: .watchlist)
        let emptySeenList = MediaList(name: "lists.seen".localized, type: .seen)
        let emptyLikedList = MediaList(name: "lists.liked".localized, type: .liked)
        let emptyDislikedList = MediaList(name: "lists.disliked".localized, type: .disliked)
        
        // Set lists to only empty default lists
        self.lists = [emptyWatchlist, emptySeenList, emptyLikedList, emptyDislikedList]
        self.watchlist = emptyWatchlist
        self.seenList = emptySeenList
        self.likedList = emptyLikedList
        self.dislikedList = emptyDislikedList
        
        // Save the empty state
        saveLists()
        
        print("✅ [ListManager] Lists cleared for logged out user - showing empty defaults only.")
    }
    
    func loadLists() {
        // Load from SQLite first (source of truth), fallback to UserDefaults
        Task {
            await loadListsFromSQLite()
            await ensureListsInDatabase()
        }
    }

    /// Load lists from SQLite (source of truth)
    /// Falls back to UserDefaults for backward compatibility with existing users
    private func loadListsFromSQLite() async {
        guard let userId = AuthService.shared.currentUser?.id else {
            loadListsFromUserDefaults()
            return
        }

        do {
            // Query 1: Load all lists for user
            let listsQuery = """
                SELECT l.id, l.name, l.description, l.type, l.created_at
                FROM lists l
                WHERE l.user_id = ?
                ORDER BY l.created_at DESC
            """
            let listRows = try await db.queryRaw(listsQuery, parameters: [userId])

            guard !listRows.isEmpty else {
                loadListsFromUserDefaults()
                return
            }

            // Query 2: Load ALL items for ALL lists in one query
            let listIds = listRows.compactMap { $0["id"] as? String }
            let placeholders = listIds.map { _ in "?" }.joined(separator: ", ")
            let itemsQuery = """
                SELECT * FROM list_items
                WHERE list_id IN (\(placeholders)) AND deleted_at IS NULL
                ORDER BY added_at DESC
            """
            let itemRows = try await db.queryRaw(itemsQuery, parameters: listIds)

            // Group items by list_id
            var itemsByListId: [String: [MediaListItem]] = [:]
            for row in itemRows {
                guard let listId = row["list_id"] as? String,
                      let item = MediaListItem.from(dictionary: row) else { continue }
                itemsByListId[listId, default: []].append(item)
            }

            // Build lists with pre-fetched items
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
            print("📋 [ListManager] Loaded \(loadedLists.count) lists with \(itemRows.count) items from SQLite (2 queries)")
        } catch {
            print("❌ [ListManager] Failed to load from SQLite: \(error)")
            loadListsFromUserDefaults()
        }
    }

    /// Legacy loader for backward compatibility
    private func loadListsFromUserDefaults() {
        if let data = UserDefaults.standard.data(forKey: "media_lists"),
           let decoded = try? JSONDecoder().decode([MediaList].self, from: data) {
            applyLists(decoded)
            print("[ListManager] Loaded \(decoded.count) lists from UserDefaults (legacy)")

            // Migrate to SQLite in background
            Task {
                await migrateListsToSQLite(decoded)
            }
        } else {
            // Initialize with default lists
            self.lists = [watchlist, seenList, likedList, dislikedList]
            saveLists()
            print("[ListManager] Initialized default lists")
        }
    }

    /// Migrate lists from UserDefaults to SQLite
    private func migrateListsToSQLite(_ lists: [MediaList]) async {
        for list in lists {
            await ensureListInSQLite(list)
            for item in list.items {
                await addItemToSQLite(item, listId: list.id)
            }
        }
        print("[ListManager] Migrated \(lists.count) lists to SQLite")
    }
    
    /// Ensure all in-memory lists exist in both SQLite and Supabase
    private func ensureListsInDatabase() async {
        // First, ensure device profile exists in SQLite (for foreign key constraint)
        await ensureDeviceProfileInSQLite()
        
        for list in lists {
            // Ensure in SQLite
            await ensureListInSQLite(list)
            
            // Ensure in Supabase if authenticated
            if authService.currentUser != nil {
                do {
                    _ = try await supabase.createList(id: list.id, name: list.name, description: list.description, type: list.type)
                    print("✅ [ListManager] Ensured list '\(list.name)' exists in Supabase")
                } catch {
                    // List might already exist, which is fine
                    print("ℹ️ [ListManager] List '\(list.name)' may already exist in Supabase: \(error)")
                }
            }
        }
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
            print("✅ [ListManager] Ensured device profile exists in SQLite")
        } else {
            print("⚠️ [ListManager] Failed to ensure device profile in SQLite")
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
            print("✅ [ListManager] Ensured list '\(list.name)' exists in SQLite")
        } else {
            print("⚠️ [ListManager] Failed to ensure list '\(list.name)' in SQLite")
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
        case .watchlist:
            return MediaList(name: "lists.watchlist".localized, type: .watchlist)
        case .seen:
            return MediaList(name: "lists.seen".localized, type: .seen)
        case .liked:
            return MediaList(name: "lists.liked".localized, type: .liked)
        case .disliked:
            return MediaList(name: "lists.disliked".localized, type: .disliked)
        case .custom:
            return MediaList(name: "Custom", type: .custom)
        }
    }
    
    func saveLists() {
        if let encoded = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(encoded, forKey: "media_lists")
        }
    }

    @discardableResult
    func fetchLists() async throws -> [MediaList] {
        guard authService.currentUser != nil else {
            loadLists()
            return lists
        }
        let remoteLists = try await supabase.fetchLists()
        applyLists(remoteLists)
        saveLists()
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
        
        // Generate a local ID first
        let listId = UUID().uuidString
        let newList = try await supabase.createList(id: listId, name: trimmedName, description: description, type: .custom)
        
        lists.append(newList)
        saveLists()
        
        // Ensure list exists in SQLite too
        Task {
            await ensureListInSQLite(newList)
        }
        
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
        if supabase.currentUser != nil {
            try await supabase.updateList(id: id, name: trimmedName, description: description)
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
        saveLists()
    }
    
    func deleteList(id: String) async throws {
        guard let index = lists.firstIndex(where: { $0.id == id }) else {
            throw ListError.listNotFound
        }
        guard lists[index].type == .custom else {
            throw ListError.defaultListImmutable
        }
        let listType = lists[index].type.rawValue
        
        if supabase.currentUser != nil {
            try await supabase.deleteList(id: id)
        }
        lists.remove(at: index)
        saveLists()
        
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
        
        // Try to sync to Supabase if authenticated (but don't fail if it doesn't work)
        if supabase.currentUser != nil {
            Task {
                do {
                    _ = try await supabase.addItemToList(listId: listId, item: item)
                    print("✅ [ListManager] Synced item to Supabase")
                } catch {
                    print("⚠️ [ListManager] Failed to sync to Supabase: \(error)")
                    // Don't throw - local save already succeeded
                }
            }
        }
        
        // Also save to local SQLite for offline access
        Task {
            await addItemToSQLite(item, listId: listId)
        }

        updateDefaultReferences(from: lists)
        notifySoftLimitIfNeeded(for: lists[index])
        saveLists()
        
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
                saveLists()
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

        // Try to sync to Supabase if authenticated (but don't fail if it doesn't work)
        if supabase.currentUser != nil {
            Task {
                do {
                    try await supabase.removeItemFromList(itemId: itemId)
                    print("✅ [ListManager] Synced removal to Supabase")
                } catch {
                    print("⚠️ [ListManager] Failed to sync removal to Supabase: \(error)")
                    // Don't throw - local removal already succeeded
                }
            }
        }

        // Also remove from local SQLite
        Task {
            await removeItemFromSQLite(itemId)
        }
        
        saveLists()
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
                userId: userId,
                tableName: "list_items",
                operationType: "DELETE",
                recordId: itemId,
                payload: ["id": itemId]
            )
            
            print("✅ [ListManager] Removed item \(itemId) from SQLite and queued for sync")
            
        } catch {
            print("❌ [ListManager] Failed to remove item from SQLite: \(error)")
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
                userId: userId,
                tableName: "list_items",
                operationType: "INSERT",
                recordId: item.id,
                payload: values
            )
            
            print("✅ [ListManager] Added item '\(item.title)' to SQLite and queued for sync")
            
        } catch {
            print("❌ [ListManager] Failed to add item to SQLite: \(error)")
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
