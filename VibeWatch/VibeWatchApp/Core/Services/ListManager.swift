import Foundation

enum ListError: Error {
    case maxListsReached(limit: Int)
    case maxItemsReached(limit: Int)
    case listNotFound
    case itemAlreadyInList
    
    var localizedDescription: String {
        switch self {
        case .maxListsReached(let limit):
            return "lists.error.maxListsReached".localized.replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .maxItemsReached(let limit):
            return "lists.error.maxItemsReached".localized.replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .listNotFound:
            return "lists.error.listNotFound".localized
        case .itemAlreadyInList:
            return "lists.error.itemAlreadyInList".localized
        }
    }
}

@MainActor
class ListManager: ObservableObject {
    static let shared = ListManager()
    
    // Limits for free tier
    static let maxCustomLists = 2
    static let maxItemsPerList = 25
    
    @Published var lists: [MediaList] = []
    @Published var watchlist: MediaList
    @Published var seenList: MediaList
    @Published var likedList: MediaList
    @Published var dislikedList: MediaList
    
    private let db = SQLiteService.shared
    private let sync = SyncWorker.shared
    private var userId: String {
        getDeviceId() // Use device ID as user ID for now
    }

    private init() {
        // Initialize default lists
        self.watchlist = MediaList(name: "lists.watchlist".localized, type: .watchlist)
        self.seenList = MediaList(name: "lists.seen".localized, type: .seen)
        self.likedList = MediaList(name: "lists.liked".localized, type: .liked)
        self.dislikedList = MediaList(name: "lists.disliked".localized, type: .disliked)

        loadLists()
    }
    
    func loadLists() {
        // Load from UserDefaults synchronously first (backward compatibility)
        if let data = UserDefaults.standard.data(forKey: "media_lists"),
           let decoded = try? JSONDecoder().decode([MediaList].self, from: data) {
            self.lists = decoded
            
            // Update default lists
            if let watchlist = decoded.first(where: { $0.type == .watchlist }) {
                self.watchlist = watchlist
            }
            if let seen = decoded.first(where: { $0.type == .seen }) {
                self.seenList = seen
            }
            if let liked = decoded.first(where: { $0.type == .liked }) {
                self.likedList = liked
            }
            if let disliked = decoded.first(where: { $0.type == .disliked }) {
                self.dislikedList = disliked
            }
            
            print("📋 [ListManager] Loaded \(decoded.count) lists from UserDefaults")
        } else {
            // Initialize with default lists
            self.lists = [watchlist, seenList, likedList, dislikedList]
            saveLists()
            print("📋 [ListManager] Initialized default lists")
        }
        
        // Also try to load from SQLite in background (don't overwrite if empty)
        Task {
            await loadListsFromSQLiteIfAvailable()
        }
    }
    
    // Load from SQLite only if data exists (don't overwrite with empty)
    private func loadListsFromSQLiteIfAvailable() async {
        do {
            let rows = try await db.queryRaw("""
                SELECT * FROM lists
                WHERE user_id = ? AND deleted_at IS NULL
                ORDER BY created_at DESC
            """, parameters: [userId])
            
            // Only update if we found data in SQLite
            if !rows.isEmpty {
                print("📋 [ListManager] Found \(rows.count) lists in SQLite, updating...")
                await loadListsFromSQLite()
            } else {
                print("📋 [ListManager] No lists in SQLite yet, keeping UserDefaults data")
            }
        } catch {
            print("⚠️ [ListManager] Failed to check SQLite: \(error)")
        }
    }
    
    // MARK: - SQLite Operations
    
    private func loadListsFromSQLite() async {
        do {
            let rows = try await db.queryRaw("""
                SELECT * FROM lists
                WHERE user_id = ? AND deleted_at IS NULL
                ORDER BY created_at DESC
            """, parameters: [userId])
            
            // Convert rows to MediaList objects
            let loadedLists = rows.compactMap { row -> MediaList? in
                guard
                    let name = row["name"] as? String,
                    let typeString = row["type"] as? String
                else { return nil }
                
                let type = ListType(rawValue: typeString) ?? .custom
                let description = row["description"] as? String
                
                // Create list (id is auto-generated, but we'll rely on UserDefaults for backward compat)
                let list = MediaList(name: name, description: description, type: type)
                
                // Note: MediaList.id is immutable, so we can't set the SQLite id directly
                // For now, rely on UserDefaults for list identity
                
                return list
            }
            
            await MainActor.run {
                self.lists = loadedLists
                
                // Update special lists references
                if let watchlist = loadedLists.first(where: { $0.type == .watchlist }) {
                    self.watchlist = watchlist
                }
                if let seen = loadedLists.first(where: { $0.type == .seen }) {
                    self.seenList = seen
                }
                if let liked = loadedLists.first(where: { $0.type == .liked }) {
                    self.likedList = liked
                }
                if let disliked = loadedLists.first(where: { $0.type == .disliked }) {
                    self.dislikedList = disliked
                }
            }
            
            print("📋 [ListManager] Loaded \(loadedLists.count) lists from SQLite successfully")
            
        } catch {
            print("⚠️ [ListManager] Failed to load lists from SQLite: \(error)")
        }
    }
    
    private func loadItemsForList(listId: String, into list: inout MediaList) async {
        do {
            let rows = try await db.queryRaw("""
                SELECT * FROM list_items
                WHERE list_id = ? AND deleted_at IS NULL
                ORDER BY added_at DESC
            """, parameters: [listId])
            
            let items = rows.compactMap { row -> MediaListItem? in
                guard
                    let mediaId = row["media_id"] as? Int,
                    let mediaTypeString = row["media_type"] as? String,
                    let title = row["title"] as? String
                else { return nil }
                
                let mediaType = MediaType(rawValue: mediaTypeString) ?? .movie
                
                // Create item (id is auto-generated)
                let item = MediaListItem(
                    mediaId: mediaId,
                    mediaType: mediaType,
                    title: title,
                    posterPath: row["poster_path"] as? String,
                    runtime: row["runtime"] as? Int,
                    voteAverage: row["vote_average"] as? Double,
                    voteCount: row["vote_count"] as? Int,
                    originCountry: parseStringArray(row["origin_country"] as? String),
                    releaseDate: row["release_date"] as? String,
                    genres: parseIntArray(row["genres"] as? String),
                    overview: row["overview"] as? String
                )
                
                // Note: MediaListItem.id is immutable
                
                return item
            }
            
            list.items = items
            
        } catch {
            print("⚠️ [ListManager] Failed to load items for list \(listId): \(error)")
        }
    }
    
    func saveLists() {
        // Deprecated - now saves to SQLite automatically
        // Keep for backward compatibility with UserDefaults
        if let encoded = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(encoded, forKey: "media_lists")
        }
    }
    
    func createList(name: String, description: String? = nil) -> Result<Void, ListError> {
        // Check if custom list limit reached
        let customListCount = lists.filter { $0.type == .custom }.count
        guard customListCount < Self.maxCustomLists else {
            return .failure(.maxListsReached(limit: Self.maxCustomLists))
        }
        
        let newList = MediaList(name: name, description: description, type: .custom)
        lists.append(newList)
        
        // Save to SQLite + queue for sync
        Task {
            await createListInSQLite(newList)
        }
        
        // Backward compatibility
        saveLists()
        
        return .success(())
    }
    
    private func createListInSQLite(_ list: MediaList) async {
        do {
            let values: [String: Any] = [
                "id": list.id,
                "user_id": userId,
                "name": list.name,
                "description": list.description ?? "",
                "type": list.type.rawValue,
                "created_at": ISO8601DateFormatter().string(from: Date())
            ]
            
            // Insert to local SQLite
            _ = try await db.insert("lists", values: values)
            
            // Queue for sync to Supabase
            try await sync.queueOperation(
                userId: userId,
                tableName: "lists",
                operationType: "INSERT",
                recordId: list.id,
                payload: values
            )
            
            print("✅ [ListManager] Created list '\(list.name)' in SQLite and queued for sync")
            
        } catch {
            print("❌ [ListManager] Failed to create list in SQLite: \(error)")
        }
    }
    
    func canCreateList() -> Bool {
        let customListCount = lists.filter { $0.type == .custom }.count
        return customListCount < Self.maxCustomLists
    }
    
    func customListsCount() -> Int {
        lists.filter { $0.type == .custom }.count
    }
    
    func deleteList(_ list: MediaList) {
        lists.removeAll { $0.id == list.id }
        
        // Delete from SQLite + queue for sync
        Task {
            await deleteListFromSQLite(list.id)
        }
        
        // Backward compatibility
        saveLists()
    }
    
    private func deleteListFromSQLite(_ listId: String) async {
        do {
            // Soft delete in local SQLite
            _ = try await db.queryRaw("""
                UPDATE lists
                SET deleted_at = datetime('now')
                WHERE id = ?
            """, parameters: [listId])
            
            // Queue for sync
            try await sync.queueOperation(
                userId: userId,
                tableName: "lists",
                operationType: "DELETE",
                recordId: listId,
                payload: ["id": listId]
            )
            
            print("✅ [ListManager] Deleted list \(listId) from SQLite and queued for sync")
            
        } catch {
            print("❌ [ListManager] Failed to delete list from SQLite: \(error)")
        }
    }
    
    func addToList(listId: String, movie: Movie, mediaType: MediaType) -> Result<Void, ListError> {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            return .failure(.listNotFound)
        }
        
        // Check if already in list
        if lists[index].items.contains(where: { $0.mediaId == movie.id && $0.mediaType == mediaType }) {
            return .failure(.itemAlreadyInList)
        }
        
        // Check item limit for custom lists
        if lists[index].type == .custom && lists[index].items.count >= Self.maxItemsPerList {
            return .failure(.maxItemsReached(limit: Self.maxItemsPerList))
        }
        
        // Extract origin country codes from production countries
        let originCountry = movie.productionCountries?.map { $0.iso }
        
        // Get genre IDs from either genreIds or genres array
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
        
        objectWillChange.send()
        lists[index].items.append(item)
        
        // Update special lists
        if lists[index].type == .watchlist {
            watchlist = lists[index]
        } else if lists[index].type == .seen {
            seenList = lists[index]
        } else if lists[index].type == .liked {
            likedList = lists[index]
        } else if lists[index].type == .disliked {
            dislikedList = lists[index]
        }
        
        // Save to SQLite + queue for sync
        Task {
            await addItemToSQLite(item, listId: listId)
        }
        
        // Backward compatibility
        saveLists()
        
        return .success(())
    }
    
    func canAddToList(listId: String) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        if list.type == .custom {
            return list.items.count < Self.maxItemsPerList
        }
        return true // No limit for default lists
    }
    
    func removeFromList(listId: String, itemId: String) {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        objectWillChange.send()
        lists[index].items.removeAll { $0.id == itemId }
        
        // Update special lists
        if lists[index].type == .watchlist {
            watchlist = lists[index]
        } else if lists[index].type == .seen {
            seenList = lists[index]
        } else if lists[index].type == .liked {
            likedList = lists[index]
        } else if lists[index].type == .disliked {
            dislikedList = lists[index]
        }
        
        // Remove from SQLite + queue for sync
        Task {
            await removeItemFromSQLite(itemId)
        }
        
        // Backward compatibility
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
