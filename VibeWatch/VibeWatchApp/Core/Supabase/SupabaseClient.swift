import Foundation
import Supabase

@MainActor
class SupabaseService: ObservableObject {
    static let shared = SupabaseService()
    
    // Delegate to AuthService for the client and user state
    var client: SupabaseClient? {
        return AuthService.shared.client
    }
    
    var currentUser: User? {
        return AuthService.shared.currentUser
    }
    
    var isAuthenticated: Bool {
        return AuthService.shared.isAuthenticated
    }
    
    private init() {}

    private let localDB = SQLiteService.shared
    
    private enum PullConflictPolicy {
        case serverWins
        case lastModified
    }

    private func conflictPolicy(for table: String) -> PullConflictPolicy {
        switch table {
        case "lists", "list_items", "user_preferences", "profiles":
            return .lastModified
        default:
            return .serverWins
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: string) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: string)
    }

    /// Check if the remote row is newer than local (by updated_at). If no local row, treat as newer.
    private func isRemoteNewer(table: String, id: String, remoteUpdatedAt: Date?) async -> Bool {
        guard let remoteUpdatedAt else { return true }
        do {
            let rows = try await localDB.queryRaw("SELECT updated_at FROM \(table) WHERE id = ? LIMIT 1", parameters: [id])
            guard let localUpdatedRaw = rows.first?["updated_at"] else { return true }
            if let localDate = parseDate(localUpdatedRaw) {
                return remoteUpdatedAt > localDate
            }
            return true
        } catch {
            return true
        }
    }

    // MARK: - Generic pull helper (stub for automated sync)
    /// Fetch latest rows for a table, optionally filtered by user_id, and upsert into local DB.
    func pullTable(name: String, userId: String?) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        var query = client.from(name).select("*")
        if let userId {
            query = query.eq("user_id", value: userId)
        }
        
        let data = try await query.execute().data

        // Decode raw JSON into [String: Any]
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        // Normalize rows per table (media_type, JSON fields)
        let normalized: [[String: Any]] = rows.map { row in
            var r = row

            // Ensure media_type is valid
            if name == "clips" || name == "list_items" {
                if let mt = r["media_type"] as? String, !["movie", "tv"].contains(mt) {
                    r["media_type"] = "movie"
                }
            }

            // Convert Postgres array (decoded as [Any]) to JSON string for local JSON columns
            func normalizeArray(_ key: String) {
                if let arr = r[key] as? [Any] {
                    if let data = try? JSONSerialization.data(withJSONObject: arr),
                       let str = String(data: data, encoding: .utf8) {
                        r[key] = str
                    }
                }
            }

            normalizeArray("genres")
            normalizeArray("actors")
            normalizeArray("keywords")
            normalizeArray("origin_country")

            return r
        }

        // Conflict handling
        let policy = conflictPolicy(for: name)
        var rowsToUpsert: [[String: Any]] = []

        switch policy {
        case .serverWins:
            rowsToUpsert = normalized
        case .lastModified:
            for row in normalized {
                guard let idAny = row["id"] else { continue }
                let idString = String(describing: idAny)
                let remoteDate = parseDate(row["updated_at"])
                let newer = await isRemoteNewer(table: name, id: idString, remoteUpdatedAt: remoteDate)
                if newer {
                    rowsToUpsert.append(row)
                }
            }
        }

        try await SQLiteService.shared.upsert(table: name, rows: rowsToUpsert)
    }

    // MARK: - Push (batch) via RPC

    /// Applies a batch of mutations atomically using the `apply_mutations` RPC on Supabase.
    /// Each mutation should include: op ('INSERT'|'UPDATE'|'DELETE'), table, id, record (JSON object).
    func applyMutations(_ batch: [[String: Any]]) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        // Manually call RPC endpoint to avoid Encodable/Any issues
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }
        let url = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("rpc")
            .appendingPathComponent("apply_mutations")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body = try JSONSerialization.data(withJSONObject: ["batch": batch], options: [])
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SupabaseError.networkError
        }
    }
    
    // MARK: - Lists
    
    func fetchLists() async throws -> [MediaList] {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        
        // Fetch lists
        struct SupabaseList: Codable {
            let id: String
            let name: String
            let description: String?
            let type: String
            let createdAt: Date
            
            enum CodingKeys: String, CodingKey {
                case id, name, description, type
                case createdAt = "created_at"
            }
        }
        
        let listsData: [SupabaseList] = try await client
            .from("lists")
            .select()
            .eq("user_id", value: userId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .value
        
        // Convert to MediaList and fetch items for each
        var mediaLists: [MediaList] = []
        for listData in listsData {
            let items = try await fetchListItems(listId: listData.id)
            let listType = ListType(databaseValue: listData.type) ?? ListType(rawValue: listData.type) ?? .custom
            
            let mediaList = MediaList(
                id: listData.id,
                name: listData.name,
                description: listData.description,
                type: listType,
                createdAt: listData.createdAt,
                items: items
            )
            mediaLists.append(mediaList)
        }
        
        return mediaLists
    }
    
    func createList(id: String, name: String, description: String?, type: ListType) async throws -> MediaList {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        
        struct CreateListRequest: Encodable {
            let id: String  // Use our local ID
            let user_id: String
            let name: String
            let description: String?
            let type: String
        }
        
        struct CreateListResponse: Decodable {
            let id: String
            let name: String
            let description: String?
            let type: String
            let created_at: Date
        }
        
        
        let request = CreateListRequest(
            id: id,  // Pass our local ID
            user_id: userId,
            name: name,
            description: description,
            type: type.rawValue
        )
        
        let response: CreateListResponse = try await client
            .from("lists")
            .insert(request)
            .select()
            .single()
            .execute()
            .value
        
        return MediaList(
            id: response.id,
            name: response.name,
            description: response.description,
            type: type,
            createdAt: response.created_at,
            items: []
        )
    }
    
    func deleteList(id: String) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        try await client
            .from("lists")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func updateList(id: String, name: String, description: String?) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        struct UpdateListRequest: Encodable {
            let name: String
            let description: String?
        }
        
        let request = UpdateListRequest(name: name, description: description)
        
        try await client
            .from("lists")
            .update(request)
            .eq("id", value: id)
            .execute()
    }
    
    // MARK: - List Items
    
    func fetchListItems(listId: String) async throws -> [MediaListItem] {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        struct SupabaseListItem: Codable {
            let id: String
            let media_id: Int
            let media_type: String
            let title: String
            let poster_path: String?
            let added_at: Date
            let runtime: Int?
            let vote_average: Double?
            let vote_count: Int?
            let origin_country: [String]?
            let release_date: String?
            let genres: [Int]?
            let overview: String?
        }
        
        let items: [SupabaseListItem] = try await client
            .from("list_items")
            .select()
            .eq("list_id", value: listId)
            .order("added_at", ascending: false)
            .execute()
            .value
        
        return items.map { item in
            MediaListItem(
                id: item.id,
                mediaId: item.media_id,
                mediaType: MediaType(rawValue: item.media_type) ?? .movie,
                title: item.title,
                posterPath: item.poster_path,
                addedAt: item.added_at,
                runtime: item.runtime,
                voteAverage: item.vote_average,
                voteCount: item.vote_count,
                originCountry: item.origin_country,
                releaseDate: item.release_date,
                genres: item.genres,
                overview: item.overview
            )
        }
    }
    
    func addItemToList(listId: String, item: MediaListItem) async throws -> MediaListItem {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        
        struct AddItemRequest: Encodable {
            let list_id: String
            let user_id: String
            let media_id: Int
            let media_type: String
            let title: String
            let poster_path: String?
            let runtime: Int?
            let vote_average: Double?
            let vote_count: Int?
            let origin_country: [String]?
            let release_date: String?
            let genres: [Int]?
            let overview: String?
        }
        
        let request = AddItemRequest(
            list_id: listId,
            user_id: userId,
            media_id: item.mediaId,
            media_type: item.mediaType.rawValue,
            title: item.title,
            poster_path: item.posterPath,
            runtime: item.runtime,
            vote_average: item.voteAverage,
            vote_count: item.voteCount,
            origin_country: item.originCountry,
            release_date: item.releaseDate,
            genres: item.genres,
            overview: item.overview
        )
        
        struct AddItemResponse: Decodable {
            let id: String
            let added_at: Date
        }
        
        let response: AddItemResponse = try await client
            .from("list_items")
            .insert(request)
            .select("id, added_at")
            .single()
            .execute()
            .value
        
        return MediaListItem(
            id: response.id,
            mediaId: item.mediaId,
            mediaType: item.mediaType,
            title: item.title,
            posterPath: item.posterPath,
            addedAt: response.added_at,
            runtime: item.runtime,
            voteAverage: item.voteAverage,
            voteCount: item.voteCount,
            originCountry: item.originCountry,
            releaseDate: item.releaseDate,
            genres: item.genres,
            overview: item.overview
        )
    }
    
    func removeItemFromList(itemId: String) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        try await client
            .from("list_items")
            .delete()
            .eq("id", value: itemId)
            .execute()
    }
    
    // MARK: - Sync
    
    func syncLocalToCloud(lists: [MediaList]) async throws {
        // Upload all local lists and items to cloud
        for list in lists {
            // Create the list with the same local ID
            let cloudList = try await createList(
                id: list.id,  // Use same ID as local
                name: list.name,
                description: list.description,
                type: list.type
            )
            
            // Add all items
            for item in list.items {
                _ = try await addItemToList(listId: cloudList.id, item: item)
            }
        }
    }
    // MARK: - AI Token Usage
    
    func logAITokenUsage(userId: UUID, tokensConsumed: Int) async throws -> Int {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        struct LogUsageRequest: Encodable {
            let p_user_id: UUID
            let p_tokens_consumed: Int
        }
        
        let request = LogUsageRequest(p_user_id: userId, p_tokens_consumed: tokensConsumed)
        
        let newTotalTokens: Int = try await client.rpc("log_ai_token_usage", params: request).execute().value
        return newTotalTokens
    }
    
    func getAITokenUsage(userId: UUID) async throws -> Int {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        struct GetUsageRequest: Encodable {
            let p_user_id: UUID
        }
        
        let request = GetUsageRequest(p_user_id: userId)
        
        let totalTokens: Int = try await client.rpc("get_ai_token_usage", params: request).execute().value
        return totalTokens
    }
}


enum SupabaseError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case authenticationFailed
    case networkError
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Please add your credentials to Config.swift"
        case .notAuthenticated:
            return "You must be signed in to perform this action"
        case .authenticationFailed:
            return "Authentication failed. Please check your credentials"
        case .networkError:
            return "Network error. Please check your connection"
        }
    }
}
