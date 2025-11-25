import Foundation

enum ListError: Error, Equatable {
    case maxListsReached(limit: Int)
    case maxItemsReached(limit: Int)
    case listNotFound
    case itemAlreadyInList
    case defaultListImmutable
    case invalidName
    case authenticationRequired
    
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
        case .defaultListImmutable:
            return "lists.error.defaultImmutable".localized
        case .invalidName:
            return "lists.error.invalidName".localized
        case .authenticationRequired:
            return "lists.error.authRequired".localized
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
    private var userId: String {
        getDeviceId() // Use device ID as user ID for now
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
    }
    
    func loadLists() {
        // Load from UserDefaults synchronously first (backward compatibility)
        if let data = UserDefaults.standard.data(forKey: "media_lists"),
           let decoded = try? JSONDecoder().decode([MediaList].self, from: data) {
            applyLists(decoded)
            print("📋 [ListManager] Loaded \(decoded.count) lists from UserDefaults")
        } else {
            // Initialize with default lists
            self.lists = [watchlist, seenList, likedList, dislikedList]
            saveLists()
            print("📋 [ListManager] Initialized default lists")
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
        guard supabase.currentUser != nil else {
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
        
        guard supabase.currentUser != nil else {
            throw ListError.authenticationRequired
        }
        
        let newList = try await supabase.createList(name: trimmedName, description: description, type: .custom)
        
        lists.append(newList)
        saveLists()
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
        if supabase.currentUser != nil {
            try await supabase.deleteList(id: id)
        }
        lists.remove(at: index)
        saveLists()
    }
    
    func canCreateList() -> Bool {
        let customListCount = lists.filter { $0.type == .custom }.count
        return customListCount < currentCustomListLimit
    }
    
    func customListsCount() -> Int {
        lists.filter { $0.type == .custom }.count
    }
    
    func addToList(listId: String, movie: Movie, mediaType: MediaType) async throws {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            throw ListError.listNotFound
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

        if supabase.currentUser != nil {
            let savedItem = try await supabase.addItemToList(listId: listId, item: item)
            objectWillChange.send()
            lists[index].items.append(savedItem)
        } else {
            objectWillChange.send()
            lists[index].items.append(item)
            Task {
                await addItemToSQLite(item, listId: listId)
            }
        }

        updateDefaultReferences(from: lists)
        notifySoftLimitIfNeeded(for: lists[index])
        saveLists()
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

        if supabase.currentUser != nil {
            try await supabase.removeItemFromList(itemId: itemId)
        }

        objectWillChange.send()
        lists[listIndex].items.removeAll { $0.id == itemId }
        updateDefaultReferences(from: lists)

        if supabase.currentUser == nil {
            Task {
                await removeItemFromSQLite(itemId)
            }
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
