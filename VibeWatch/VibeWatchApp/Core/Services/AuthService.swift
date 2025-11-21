import Foundation
import Supabase
import Auth
import AuthenticationServices

@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()
    
    // Real Supabase credentials
    private let supabaseURL = "https://rqhxhkijzhqivljivirq.supabase.co"
    private let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJxaHhoa2lqemhxaXZsaml2aXJxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjMwNjc5ODgsImV4cCI6MjA3ODY0Mzk4OH0.D5OV0RX_whGawCu5xPfWX8297XyeXcjBOxsWez-fqVA"
    
    private(set) var client: Supabase.SupabaseClient?
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    
    private init() {
        setupClient()
        print("✅ AuthService initialized with real Supabase")
    }
    
    private func setupClient() {
        guard !supabaseURL.isEmpty && supabaseURL != "YOUR_SUPABASE_URL",
              !supabaseAnonKey.isEmpty && supabaseAnonKey != "YOUR_SUPABASE_ANON_KEY" else {
            print("⚠️ Supabase credentials not configured")
            return
        }
        
        guard let url = URL(string: supabaseURL) else {
            print("❌ Invalid Supabase URL")
            return
        }
        
        client = Supabase.SupabaseClient(supabaseURL: url, supabaseKey: supabaseAnonKey)
        
        // Check initial auth state
        Task {
            await checkAuthState()
        }
    }
    
    // MARK: - Authentication State
    
    func checkAuthState() async {
        guard let client = client else { return }
        
        do {
            let session = try await client.auth.session
            await fetchUserProfile(userId: session.user.id.uuidString)
        } catch {
            print("No active session: \(error.localizedDescription)")
            self.currentUser = nil
            self.isAuthenticated = false
        }
    }
    
    // MARK: - Email/Password Authentication
    
    func signUp(username: String, email: String, password: String) async throws -> User {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        do {
            print("📝 Attempting to sign up user: \(email)")
            
            // FIX: Pass username as metadata so the DB trigger can use it
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(username)]
            )
            
            let userId = response.user.id.uuidString
            print("✅ Auth user created with ID: \(userId)")
            
            // Wait a moment for the trigger to create the user profile
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Try to fetch the profile created by the trigger
            await fetchUserProfile(userId: userId)
            
            // If profile wasn't created by trigger, create it manually
            if currentUser == nil {
                print("⚠️ Trigger didn't create profile, creating manually...")
                let newUser = User(
                    id: userId,
                    email: email,
                    displayName: username,
                    avatarURL: nil
                )
                
                do {
                    // Upsert the profile
                    try await updateUserProfileDirectly(user: newUser)
                    print("✅ Profile created manually successfully")
                    
                    self.currentUser = newUser
                    self.isAuthenticated = true
                } catch {
                    print("❌ Error creating profile manually: \(error)")
                    throw AuthError.databaseError
                }
            } else if let user = currentUser, (user.displayName == nil || user.displayName == "") {
                // Profile exists but needs username (Trigger might have failed to copy metadata)
                print("📝 Updating existing profile with username")
                try await updateUserProfile(displayName: username, avatarURL: nil)
            }
            
            print("✅ User created successfully with Supabase")
            
            guard let user = currentUser else {
                throw AuthError.userNotFound
            }
            
            return user
        } catch let error as AuthError {
            print("❌ AuthError: \(error)")
            throw error
        } catch {
            print("❌ Unexpected error during signup: \(error)")
            throw AuthError.signUpFailed
        }
    }
    
    func signIn(emailOrUsername: String, password: String) async throws -> User {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        // Check if input is email or username
        let email: String
        if emailOrUsername.contains("@") {
            email = emailOrUsername
        } else {
            // Fetch email from username
            email = try await getEmailFromUsername(emailOrUsername)
        }
        
        // Sign in with email and password
        let response = try await client.auth.signIn(
            email: email,
            password: password
        )
        
        let userId = response.user.id.uuidString
        
        // Fetch user profile
        await fetchUserProfile(userId: userId)
        
        guard let user = currentUser else {
            throw AuthError.userNotFound
        }
        
        print("✅ User signed in successfully with Supabase")
        
        return user
    }
    
    func signOut() async throws {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        try await client.auth.signOut()
        
        self.currentUser = nil
        self.isAuthenticated = false
        
        print("✅ User signed out successfully")
    }
    
    // MARK: - Social Authentication
    
    func signInWithApple() async throws -> User {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        print("🍎 Starting Apple Sign In...")
        
        // Sign in with Apple OAuth
        try await client.auth.signInWithOAuth(
            provider: .apple,
            redirectTo: URL(string: "com.vibewatch.VibeWatchApp://auth/callback")
        )
        
        // Wait for auth to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Check auth state and fetch profile
        await checkAuthState()
        
        guard let user = currentUser else {
            throw AuthError.userNotFound
        }
        
        print("✅ Apple Sign In successful")
        return user
    }
    
    func signInWithGoogle() async throws -> User {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        print("🔍 Starting Google Sign In...")
        
        // Sign in with Google OAuth
        try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "com.vibewatch.VibeWatchApp://auth/callback")
        )
        
        // Wait for auth to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Check auth state and fetch profile
        await checkAuthState()
        
        guard let user = currentUser else {
            throw AuthError.userNotFound
        }
        
        print("✅ Google Sign In successful")
        return user
    }
    
    
    // MARK: - User Profile Management
    private func fetchUserProfile(userId: String) async {
            guard let client = client else { 
                print("❌ Client not configured in fetchUserProfile")
                return 
            }
            
            print("📥 Fetching profile for user ID: \(userId)")
            
            // Wait a bit for the trigger to create the profile
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Defined inner function to perform the actual fetch
            func performFetch() async throws -> User {
                return try await client
                    .from("profiles")
                    .select()
                    .eq("id", value: userId)
                    .single()
                    .execute()
                    .value
            }
            
            do {
                // Attempt 1: Standard Fetch
                print("🔍 Attempting to fetch profile from database...")
                let response = try await performFetch()
                self.currentUser = response
                self.isAuthenticated = true
                print("✅ User profile fetched successfully: \(response.email)")
                print("   Display name: \(response.displayName ?? "nil")")
                print("   Avatar URL: \(response.avatarURL ?? "nil")")
                
                if response.displayName == nil || response.displayName?.isEmpty == true {
                    await updateDisplayNameFromMetadata(userId: userId)
                }
            } catch let fetchError {
                print("❌ First fetch failed: \(fetchError)")
                print("⚠️ Attempting metadata sync/recovery...")
                
                // Attempt 2: Run the metadata sync to fix missing display names
                await updateDisplayNameFromMetadata(userId: userId)
                
                // Attempt 3: Try fetching ONE MORE TIME after the sync
                do {
                    print("🔍 Retrying profile fetch after metadata sync...")
                    let retryResponse = try await performFetch()
                    self.currentUser = retryResponse
                    self.isAuthenticated = true
                    print("✅ User profile fetched after recovery: \(retryResponse.email)")
                } catch let retryError {
                    print("❌ Final fetch failed: \(retryError)")
                    print("❌ This will cause 'User not found' error in sign in")
                    // Ensure currentUser is nil so signUp knows to try manual creation
                    self.currentUser = nil
                }
            }
        }
    
    private func getEmailFromUsername(_ username: String) async throws -> String {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        do {
            print("🔍 Looking up email for username: '\(username)'")
            
            // Try exact match first
            let response: User = try await client
                .from("profiles")
                .select()
                .eq("display_name", value: username)
                .single()
                .execute()
                .value
            
            print("✅ Found email for username: \(response.email)")
            return response.email
        } catch let exactError {
            print("❌ Exact match failed for username: '\(username)'")
            print("❌ Error details: \(exactError)")
            
            // Try case-insensitive search as fallback
            do {
                print("🔍 Trying case-insensitive search...")
                
                let response: User = try await client
                    .from("profiles")
                    .select()
                    .ilike("display_name", pattern: username)
                    .single()
                    .execute()
                    .value
                
                print("✅ Found email with case-insensitive search: \(response.email)")
                return response.email
            } catch {
                print("❌ Case-insensitive search also failed")
                print("❌ Error details: \(error)")
                throw AuthError.userNotFound
            }
        }
    }
    
    func updateUserProfile(displayName: String?, avatarURL: String?) async throws {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        guard var user = currentUser else {
            throw AuthError.userNotFound
        }
        
        // Prepare update data dictionary
        var updateData: [String: String] = [:]
        
        if let displayName = displayName {
            user.displayName = displayName
            updateData["display_name"] = displayName
        }
        
        if let avatarURL = avatarURL {
            user.avatarURL = avatarURL
            updateData["avatar_url"] = avatarURL
        }
        
        guard !updateData.isEmpty else { return }
        
        print("📝 Updating profile for user \(user.id) with data: \(updateData)")
        
        try await client
            .from("profiles")
            .update(updateData)
            .eq("id", value: user.id)
            .execute()
        
        self.currentUser = user
        print("✅ Profile updated successfully in database")
    }
    
    func uploadAvatar(imageData: Data) async throws -> String {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw AuthError.userNotFound
        }
        
        // Generate unique file name
        let fileName = "\(userId)-\(UUID().uuidString).jpg"
        
        print("📤 Uploading avatar: \(fileName)")
        
        do {
            // Upload to Supabase Storage
            try await client.storage
                .from("avatars")
                .upload(fileName, data: imageData, options: .init(contentType: "image/jpeg", upsert: true))
            
            print("✅ Avatar file uploaded to storage")
            
            // Get public URL
            let publicURL = try client.storage
                .from("avatars")
                .getPublicURL(path: fileName)
            
            print("✅ Avatar public URL generated: \(publicURL)")
            
            // Update user profile with new avatar URL
            try await updateUserProfile(displayName: nil, avatarURL: publicURL.absoluteString)
            
            print("✅ Avatar upload complete and profile updated")
            
            return publicURL.absoluteString
        } catch {
            print("❌ Error uploading avatar: \(error)")
            throw error
        }
    }
    
    private func updateUserProfileDirectly(user: User) async throws {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        // Use upsert to create or update the profile
        struct ProfileUpdate: Encodable {
            let id: String
            let email: String
            let display_name: String?
            let avatar_url: String?
        }
        
        let profileData = ProfileUpdate(
            id: user.id,
            email: user.email,
            display_name: user.displayName,
            avatar_url: user.avatarURL
        )
        
        try await client
            .from("profiles")
            .upsert(profileData)
            .execute()
    }
    
    private func updateDisplayNameFromMetadata(userId: String) async {
        guard let client = client else { return }
        
        do {
            let session = try await client.auth.session
            let authUser = session.user
            
            // Debug: Print all metadata
            print("📋 User metadata: \(authUser.userMetadata)")
            
            // Extract name from auth metadata (try multiple fields)
            var displayName: String? = nil
            
            // Check common metadata keys
            if let metaDisplay = authUser.userMetadata["display_name"] {
                displayName = String(describing: metaDisplay)
            } else if let fullName = authUser.userMetadata["full_name"] {
                displayName = String(describing: fullName)
            } else if let name = authUser.userMetadata["name"] {
                displayName = String(describing: name)
            } else if let userName = authUser.userMetadata["user_name"] {
                displayName = String(describing: userName)
            }
            
            print("📝 Extracted display name: \(displayName ?? "nil")")
            
            // Extract avatar URL
            var avatarURL: String? = nil
            if let picture = authUser.userMetadata["picture"] {
                avatarURL = String(describing: picture)
            } else if let avatarUrl = authUser.userMetadata["avatar_url"] {
                avatarURL = String(describing: avatarUrl)
            }
            
            // If we found nothing, we can't update
            if displayName == nil && avatarURL == nil { return }
            
            // Build update data
            var updateData: [String: String] = [:]
            
            if let name = displayName {
                updateData["display_name"] = name
            }
            
            if let avatar = avatarURL {
                updateData["avatar_url"] = avatar
            }
            
            // Update database
            try await client
                .from("profiles")
                .update(updateData)
                .eq("id", value: userId)
                .execute()
            
            // Update local state
            if let name = displayName {
                self.currentUser?.displayName = name
            }
            if let avatar = avatarURL {
                self.currentUser?.avatarURL = avatar
            }
            print("✅ Synced profile from metadata")
            
        } catch {
            print("❌ Error syncing from metadata: \(error.localizedDescription)")
        }
    }
}

enum AuthError: LocalizedError {
    case notConfigured
    case invalidResponse
    case userNotFound
    case invalidCredentials
    case networkError
    case databaseError
    case signUpFailed
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Authentication service is not configured. Please add your Supabase credentials."
        case .invalidResponse:
            return "Invalid response from server."
        case .userNotFound:
            return "User not found."
        case .invalidCredentials:
            return "Invalid email or password."
        case .networkError:
            return "Network error. Please check your connection."
        case .databaseError:
            return "Database error saving user profile. Please try again."
        case .signUpFailed:
            return "Sign up failed. Please try again."
        }
    }
}
