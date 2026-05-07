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
    
    private init() {
        if let savedDeviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            self.deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "deviceIdentifier")
            self.deviceId = newDeviceId
        }
    }

    private let localDB = SQLiteService.shared
    private let deviceId: String

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func localDayKey(for date: Date = Date()) -> String {
        Self.dayKeyFormatter.string(from: date)
    }

    private func isDateInTodayLocal(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    private func normalizeUserId(_ userId: String) -> String {
        userId.lowercased()
    }

    private struct LocalAITokenUsageState {
        let tokens: Int
        let didResetForNewDay: Bool
    }

    /// Ensures the cached `user_ai_token_usage` row is for the current local day.
    /// Returns the corrected cached value (0 if it was reset).
    private func normalizeLocalAITokenUsageForToday(userId: String) async -> LocalAITokenUsageState? {
        let normalizedUserId = normalizeUserId(userId)
        let todayKey = localDayKey()

        do {
            let rows = try await localDB.queryRaw(
                "SELECT tokens_used_today, usage_day, updated_at FROM user_ai_token_usage WHERE user_id = ? LIMIT 1",
                parameters: [normalizedUserId]
            )
            guard let row = rows.first else { return nil }

            let tokens = row["tokens_used_today"] as? Int ?? 0
            let usageDay = row["usage_day"] as? String
            let updatedAt = parseDate(row["updated_at"])

            if let usageDay {
                if usageDay == todayKey {
                    return LocalAITokenUsageState(tokens: tokens, didResetForNewDay: false)
                }
            } else if let updatedAt, isDateInTodayLocal(updatedAt) {
                // Backfill day without resetting if the timestamp is still "today".
                let now = ISO8601DateFormatter().string(from: Date())
                let update: [String: Any] = [
                    "user_id": normalizedUserId,
                    "tokens_used_today": tokens,
                    "usage_day": todayKey,
                    "updated_at": now
                ]
                try? await localDB.upsert(table: "user_ai_token_usage", rows: [update])
                return LocalAITokenUsageState(tokens: tokens, didResetForNewDay: false)
            }

            // New day (or unknown): reset locally.
            await resetLocalAITokenUsage(userId: normalizedUserId)
            return LocalAITokenUsageState(tokens: 0, didResetForNewDay: true)
        } catch {
            Logger.warning("[SQLite] Failed to read cached AI token usage: \(error.localizedDescription)")
            return nil
        }
    }

    private func resetLocalAITokenUsage(userId: String) async {
        let normalizedUserId = normalizeUserId(userId)
        let now = ISO8601DateFormatter().string(from: Date())
        let todayKey = localDayKey()
        let row: [String: Any] = [
            "user_id": normalizedUserId,
            "tokens_used_today": 0,
            "usage_day": todayKey,
            "updated_at": now
        ]
        do {
            try await localDB.upsert(table: "user_ai_token_usage", rows: [row])
            NotificationCenter.default.post(name: .aiTokenUsageDidReset, object: nil)
            Logger.debug("[SQLite] Reset cached AI tokens for user \(normalizedUserId) (day=\(todayKey))")
        } catch {
            Logger.warning("[SQLite] Failed to reset cached AI token usage locally: \(error.localizedDescription)")
        }
    }

    /// Best-effort: reset the remote `user_ai_token_usage` row to 0 (used when local midnight passes).
    private func resetRemoteAITokenUsageIfPossible(userId: String) async {
        guard let client else { return }

        struct ResetUpdate: Encodable {
            let tokens_used_today: Int
            let updated_at: String
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let payload = ResetUpdate(tokens_used_today: 0, updated_at: now)

        do {
            try await client
                .from("user_ai_token_usage")
                .update(payload)
                .eq("user_id", value: normalizeUserId(userId))
                .execute()
        } catch {
            // Ignore: offline / RLS / schema differences should not break local quota behavior.
            Logger.warning("[Supabase] Failed to reset remote AI token usage: \(error.localizedDescription)")
        }
    }

    /// Called by app-level day-change handlers to enforce local-midnight reset.
    func handleLocalDayBoundaryForCurrentUser() async {
        guard let userId = currentUser?.id else { return }
        let normalized = normalizeUserId(userId)
        let state = await normalizeLocalAITokenUsageForToday(userId: normalized)
        if state?.didResetForNewDay == true {
            await resetRemoteAITokenUsageIfPossible(userId: normalized)
        }
    }
    
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

    // MARK: - Clip Signals

    func logClipSignal(
        clipId: String,
        signalType: String,
        signalValue: Double,
        context: AnalyticsContext? = nil
    ) async {
        guard let userId = currentUser?.id else { return }

        let recordId = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())

        let values: [String: Any] = [
            "id": recordId,
            "user_id": userId,
            "device_id": deviceId,
            "clip_id": clipId,
            "signal_type": signalType,
            "signal_value": signalValue,
            "source": context?.source ?? NSNull(),
            "position": context?.position ?? NSNull(),
            "session_id": context?.sessionId ?? NSNull(),
            "occurred_at": now,
            "synced_at": NSNull()
        ]

        do {
            _ = try await localDB.insert("user_clip_signals", values: values)
            try await SyncEngine.shared.queueOperation(
                table: "user_clip_signals",
                operationType: "INSERT",
                recordId: recordId,
                payload: values,
                dependsOn: nil
            )
        } catch {
            Logger.error("[Supabase] Failed to log clip signal", error: error)
        }
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
        guard let client else {
            throw SupabaseError.notConfigured
        }
        
        var query = client.from(name).select("*")
        if let userId {
            if name == "profiles" {
                query = query.eq("id", value: userId) // profiles table uses id, not user_id
            } else {
                query = query.eq("user_id", value: userId)
            }
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
        guard client != nil else {
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
        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        let body = try JSONSerialization.data(withJSONObject: ["batch": batch], options: [])
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        if (200...299).contains(http.statusCode) {
            return
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""

        // If the RPC isn't deployed yet, fall back to client-side REST operations.
        if http.statusCode == 404 || bodyString.lowercased().contains("apply_mutations") {
            try await applyMutationsClientSide(batch)
            return
        }

        throw SupabaseError.httpError(statusCode: http.statusCode, body: bodyString)
    }

    // MARK: - Preferences RPC

    func mergeUserPreferences(userId: UUID, preferences: [[String: Any]]) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "p_user_id": userId.uuidString.lowercased(),
            "p_preferences": preferences
        ]

        let data = try await callRPC(function: "merge_user_preferences", payload: payload)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func callRPC(function: String, payload: [String: Any]) async throws -> Data {
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }

        let url = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("rpc")
            .appendingPathComponent(function)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }

        return data
    }

    // MARK: - Generic REST Upsert

    func upsertRow(
        table: String,
        onConflict: String,
        record: [String: Any]
    ) async throws {
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }

        var components = URLComponents(url: baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: onConflict)]

        guard let url = components?.url else {
            throw SupabaseError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")

        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: record, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    private func deleteRow(table: String, id: String) async throws {
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }

        var components = URLComponents(url: baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]

        guard let url = components?.url else {
            throw SupabaseError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    private func applyMutationsClientSide(_ batch: [[String: Any]]) async throws {
        for mutation in batch {
            let op = (mutation["op"] as? String)?.uppercased() ?? "UPSERT"
            guard let table = mutation["table"] as? String else { continue }
            let mutationId = mutation["id"] as? String
            var record = mutation["record"] as? [String: Any] ?? [:]

            if let mutationId, !mutationId.isEmpty, record["id"] == nil {
                record["id"] = mutationId
            }

            switch op {
            case "DELETE":
                if let id = (mutationId ?? record["id"] as? String), !id.isEmpty {
                    try await deleteRow(table: table, id: id)
                }
            default:
                try await upsertRow(table: table, onConflict: "id", record: record)
            }
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
        
        // Fetch all lists' items in parallel
        let mediaLists: [MediaList] = try await withThrowingTaskGroup(of: MediaList.self) { group in
            for listData in listsData {
                group.addTask {
                    let items = try await self.fetchListItems(listId: listData.id)
                    let listType = ListType(databaseValue: listData.type) ?? ListType(rawValue: listData.type) ?? .custom
                    return MediaList(
                        id: listData.id,
                        name: listData.name,
                        description: listData.description,
                        type: listType,
                        createdAt: listData.createdAt,
                        items: items
                    )
                }
            }
            var results: [MediaList] = []
            for try await list in group {
                results.append(list)
            }
            return results
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
        
        // Try to use remote RPC first; if it fails (e.g., missing function in debug), fall back to local cache.
        let normalizedUserId = userId.uuidString.lowercased()
        let state = await normalizeLocalAITokenUsageForToday(userId: normalizedUserId)
        if state?.didResetForNewDay == true {
            await resetRemoteAITokenUsageIfPossible(userId: normalizedUserId)
        }
        
        struct LogUsageRequest: Encodable {
            let p_user_id: UUID
            let p_tokens_consumed: Int
        }
        
        let request = LogUsageRequest(p_user_id: userId, p_tokens_consumed: tokensConsumed)
        do {
            let newTotalTokens: Int = try await client.rpc("log_ai_token_usage", params: request).execute().value
            await saveLocalAITokenUsage(userId: normalizedUserId, tokensUsed: newTotalTokens)
            return newTotalTokens
        } catch {
            // Fallback: update local cache so UI stays consistent even if RPC is unavailable (common in debug).
            let currentLocal = await getLocalAITokenUsage(userId: normalizedUserId) ?? 0
            let fallbackTotal = currentLocal + tokensConsumed
            await saveLocalAITokenUsage(userId: normalizedUserId, tokensUsed: fallbackTotal)
            Logger.warning("[Supabase] log_ai_token_usage RPC failed; using local fallback. Error: \(error.localizedDescription)")
            return fallbackTotal
        }
    }
    
    func getAITokenUsage(userId: UUID) async throws -> Int {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }

        let normalizedUserId = userId.uuidString.lowercased()
        let state = await normalizeLocalAITokenUsageForToday(userId: normalizedUserId)
        if state?.didResetForNewDay == true {
            await resetRemoteAITokenUsageIfPossible(userId: normalizedUserId)
        }
        
        struct GetUsageRequest: Encodable {
            let p_user_id: UUID
        }
        
        let request = GetUsageRequest(p_user_id: userId)
        
        do {
            let totalTokens: Int = try await client.rpc("get_ai_token_usage", params: request).execute().value

            // Cache locally for offline state (normalize casing)
            await saveLocalAITokenUsage(userId: normalizedUserId, tokensUsed: totalTokens)
            return totalTokens
        } catch {
            Logger.warning("[Supabase] get_ai_token_usage RPC failed; using local cache. Error: \(error.localizedDescription)")
            return await getLocalAITokenUsage(userId: normalizedUserId) ?? 0
        }
    }
    
    /// Cache AI token usage locally so the UI can reflect changes immediately/offline.
    func saveLocalAITokenUsage(userId: String, tokensUsed: Int) async {
        let normalizedUserId = normalizeUserId(userId)
        let now = ISO8601DateFormatter().string(from: Date())
        let todayKey = localDayKey()
        let row: [String: Any] = [
            "user_id": normalizedUserId,
            "tokens_used_today": tokensUsed,
            "usage_day": todayKey,
            "updated_at": now
        ]
        do {
            try await localDB.upsert(table: "user_ai_token_usage", rows: [row])
            Logger.debug("[SQLite] Cached AI tokens: \(tokensUsed) for user \(normalizedUserId)")
        } catch {
            Logger.warning("[SQLite] Failed to cache AI token usage locally: \(error.localizedDescription)")
        }
    }
    
    /// Read cached AI token usage from local SQLite (if available).
    func getLocalAITokenUsage(userId: String) async -> Int? {
        await normalizeLocalAITokenUsageForToday(userId: userId)?.tokens
    }

    // MARK: - User Profile

    /// Update user profile fields in Supabase
    func updateUserProfile(_ fields: [String: Any]) async throws {
        guard let client = client, let userId = currentUser?.id else {
            throw SupabaseError.notConfigured
        }

        var updateFields = fields
        updateFields["updated_at"] = ISO8601DateFormatter().string(from: Date())

        // Build the update payload as Encodable
        struct ProfileUpdate: Encodable {
            let onboarding_completed: Bool?
            let onboarding_completed_at: String?
            let updated_at: String

            init(from fields: [String: Any]) {
                self.onboarding_completed = fields["onboarding_completed"] as? Bool
                self.onboarding_completed_at = fields["onboarding_completed_at"] as? String
                self.updated_at = fields["updated_at"] as? String ?? ISO8601DateFormatter().string(from: Date())
            }
        }

        let update = ProfileUpdate(from: updateFields)

        try await client.from("profiles")
            .update(update)
            .eq("id", value: userId)
            .execute()

        Logger.info("[Supabase] Updated user profile")
    }

    /// Fetch user profile from Supabase
    func fetchUserProfile() async throws -> [String: Any]? {
        guard let client = client, let userId = currentUser?.id else {
            return nil
        }

        let response = try await client.from("profiles")
            .select()
            .eq("id", value: userId)
            .limit(1)
            .execute()

        guard let rows = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]],
              let profile = rows.first else {
            return nil
        }

        return profile
    }

}

extension Notification.Name {
    static let aiTokenUsageDidReset = Notification.Name("aiTokenUsageDidReset")
}


enum SupabaseError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case authenticationFailed
    case networkError
    case httpError(statusCode: Int, body: String)
    
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
        case .httpError(let statusCode, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            return "Supabase HTTP \(statusCode): \(short.isEmpty ? "No response body" : short)"
        }
    }
}
