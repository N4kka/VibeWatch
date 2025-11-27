import Foundation
import Supabase

@MainActor
class SupabaseService: ObservableObject {
    static let shared = SupabaseService()
    
    // Public accessor for database operations (auth not required for reads)
    var client: SupabaseClient? {
        return _client
    }
    
    private var _client: SupabaseClient?
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    
    private init() {
        // Initialize client if credentials are configured
        if let url = URL(string: Config.supabaseURL),
           !Config.supabaseAnonKey.isEmpty {
            _client = SupabaseClient(
                supabaseURL: url,
                supabaseKey: Config.supabaseAnonKey
            )
            
            // Check for existing session (optional - works without auth for public tables)
            Task {
                await checkSession()
            }
        } else {
            print("⚠️ Supabase not configured. Add credentials to Config.swift")
        }
    }
    
    // MARK: - Session Management
    
    private func checkSession() async {
        guard let client = _client else { return }
        
        do {
            let session = try await client.auth.session
            let user = session.user
            currentUser = User(
                id: user.id.uuidString,
                email: user.email ?? "",
                displayName: nil,
                avatarURL: nil
            )
            isAuthenticated = true
        } catch {
            print("No active session: \(error)")
            isAuthenticated = false
        }
    }
    
    // MARK: - Authentication
    
    func signUp(email: String, password: String) async throws -> User {
        guard let client = _client else {
            throw SupabaseError.notConfigured
        }
        
        let response = try await client.auth.signUp(email: email, password: password)
        let user = response.user
        
        let newUser = User(
            id: user.id.uuidString,
            email: email,
            displayName: nil,
            avatarURL: nil
        )
        
        currentUser = newUser
        isAuthenticated = true
        
        return newUser
    }
    
    func signIn(email: String, password: String) async throws -> User {
        guard let client = _client else {
            throw SupabaseError.notConfigured
        }
        
        let response = try await client.auth.signIn(email: email, password: password)
        
        let user = User(
            id: response.user.id.uuidString,
            email: email,
            displayName: nil,
            avatarURL: nil
        )
        
        currentUser = user
        isAuthenticated = true
        
        return user
    }
    
    func signOut() async throws {
        guard let client = _client else {
            throw SupabaseError.notConfigured
        }
        
        try await client.auth.signOut()
        currentUser = nil
        isAuthenticated = false
    }
    
    func getCurrentUser() async throws -> User? {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        let session = try await client.auth.session
        
        let user = User(
            id: session.user.id.uuidString,
            email: session.user.email ?? "",
            displayName: nil,
            avatarURL: nil
        )
        
        currentUser = user
        isAuthenticated = true
        
        return user
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
