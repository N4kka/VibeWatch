import Foundation
// TODO: Uncomment when Supabase package is properly linked in Xcode
// import Supabase

class SupabaseClient {
    static let shared = SupabaseClient()
    
    private let supabaseURL = "" // TODO: Add your Supabase URL here
    private let supabaseKey = "" // TODO: Add your Supabase anon key here
    
    // Temporarily disabled - needs Supabase package properly linked
    var client: Any? = nil
    /*
    lazy var client: SupabaseClient? = {
        guard !supabaseURL.isEmpty, !supabaseKey.isEmpty else {
            print("⚠️ Supabase credentials not configured")
            return nil
        }
        
        return SupabaseClient(
            supabaseURL: URL(string: supabaseURL)!,
            supabaseKey: supabaseKey
        )
    }()
    */
    
    private init() {}
    
    func signUp(email: String, password: String) async throws -> User {
        // Temporarily disabled - will work once Supabase is properly linked
        throw SupabaseError.notConfigured
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        let response = try await client.auth.signUp(email: email, password: password)
        
        // TODO: Map Supabase user to app User model
        return User(
            id: response.user.id.uuidString,
            email: email,
            displayName: nil,
            avatarURL: nil,
            selectedProviders: [],
            createdAt: Date()
        )
        */
    }
    
    func signIn(email: String, password: String) async throws -> User {
        // Temporarily disabled - will work once Supabase is properly linked
        throw SupabaseError.notConfigured
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        let response = try await client.auth.signIn(email: email, password: password)
        
        // TODO: Map Supabase user to app User model
        return User(
            id: response.user.id.uuidString,
            email: email,
            displayName: nil,
            avatarURL: nil,
            selectedProviders: [],
            createdAt: Date()
        )
        */
    }
    
    func signOut() async throws {
        throw SupabaseError.notConfigured
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        try await client.auth.signOut()
        */
    }
    
    func getCurrentUser() async throws -> User? {
        return nil
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let session = try await client.auth.session else {
            return nil
        }
        
        // TODO: Fetch user profile from database
        return User(
            id: session.user.id.uuidString,
            email: session.user.email ?? "",
            displayName: nil,
            avatarURL: nil,
            selectedProviders: [],
            createdAt: Date()
        )
        */
    }
    
    // MARK: - Lists
    
    func getLists(userId: String) async throws -> [MediaList] {
        return []
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        let response: [MediaList] = try await client
            .from("lists")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
        
        return response
        */
    }
    
    func createList(userId: String, title: String, description: String?) async throws -> MediaList {
        throw SupabaseError.notConfigured
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        let newList = MediaList(
            id: UUID().uuidString,
            userId: userId,
            title: title,
            description: description,
            visibility: .private,
            items: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        
        let response: MediaList = try await client
            .from("lists")
            .insert(newList)
            .single()
            .execute()
            .value
        
        return response
        */
    }
    
    // MARK: - Clips
    
    func getClips(page: Int = 1, limit: Int = 20) async throws -> [Clip] {
        return []
        /*
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        let from = (page - 1) * limit
        let to = from + limit - 1
        
        let response: [Clip] = try await client
            .from("clips")
            .select()
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        
        return response
        */
    }
}

enum SupabaseError: LocalizedError {
    case notConfigured
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Please add your credentials."
        }
    }
}
