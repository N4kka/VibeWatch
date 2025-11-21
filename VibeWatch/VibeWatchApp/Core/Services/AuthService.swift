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
            
            // Sign up with email and password
            let response = try await client.auth.signUp(
                email: email,
                password: password
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
                    print("✅ Profile created successfully")
                    
                    self.currentUser = newUser
                    self.isAuthenticated = true
                } catch {
                    print("❌ Error creating profile: \(error)")
                    print("❌ Error details: \(error.localizedDescription)")
                    throw AuthError.databaseError
                }
            } else if let user = currentUser, user.displayName == nil && !username.isEmpty {
                // Profile exists but needs username
                print("📝 Updating existing profile with username")
                var updatedUser = user
                updatedUser.displayName = username
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
            print("❌ Error type: \(type(of: error))")
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
        guard let client = client else { return }
        
        // Wait a bit for the trigger to create the profile
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        do {
            let response: User = try await client
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            
            self.currentUser = response
            self.isAuthenticated = true
            print("✅ User profile fetched successfully")
            
            // Check if display_name is missing and update from auth metadata
            if response.displayName == nil || response.displayName?.isEmpty == true {
                print("⚠️ Display name is missing, extracting from auth metadata...")
                await updateDisplayNameFromMetadata(userId: userId)
            }
        } catch {
            print("⚠️ Error fetching user profile: \(error.localizedDescription)")
            print("⚠️ Attempting to update existing profile...")
            
            // Profile exists but fetch failed, or needs to be created
            // Try updating instead of inserting
            do {
                let session = try await client.auth.session
                let authUser = session.user
                
                // Debug: Print all metadata
                print("📋 User metadata: \(authUser.userMetadata)")
                print("📋 Metadata type: \(type(of: authUser.userMetadata))")
                
                // Extract name from auth metadata (try multiple fields)
                // The metadata might be AnyJSON, need to handle properly
                var displayName: String? = nil
                
                // Try extracting from different possible keys
                if let fullName = authUser.userMetadata["full_name"] {
                    displayName = String(describing: fullName)
                    print("🔍 Found full_name: \(fullName)")
                } else if let name = authUser.userMetadata["name"] {
                    displayName = String(describing: name)
                    print("🔍 Found name: \(name)")
                } else if let userName = authUser.userMetadata["user_name"] {
                    displayName = String(describing: userName)
                    print("🔍 Found user_name: \(userName)")
                } else if let email = authUser.email {
                    // Fallback: use email prefix for Apple users (Apple often doesn't provide name)
                    displayName = email.split(separator: "@").first.map(String.init)
                    print("🔍 Using email prefix as name: \(displayName ?? "nil")")
                }
                
                print("📝 Extracted display name: \(displayName ?? "nil")")
                
                // Extract avatar URL from metadata (try multiple fields)
                var avatarURL: String? = nil
                
                if let picture = authUser.userMetadata["picture"] {
                    avatarURL = String(describing: picture)
                    print("🔍 Found picture: \(picture)")
                } else if let avatarUrl = authUser.userMetadata["avatar_url"] {
                    avatarURL = String(describing: avatarUrl)
                    print("🔍 Found avatar_url: \(avatarUrl)")
                }
                
                print("📝 Extracted avatar URL: \(avatarURL ?? "nil")")
                
                let newUser = User(
                    id: authUser.id.uuidString,
                    email: authUser.email ?? "",
                    displayName: displayName,
                    avatarURL: avatarURL
                )
                
                // Try to update the existing row (created by trigger)
                var updateData: [String: String] = [
                    "email": authUser.email ?? ""
                ]
                
                if let name = displayName {
                    updateData["display_name"] = name
                }
                
                if let avatar = avatarURL {
                    updateData["avatar_url"] = avatar
                }
                
                try await client
                    .from("profiles")
                    .update(updateData)
                    .eq("id", value: authUser.id.uuidString)
                    .execute()
                
                self.currentUser = newUser
                self.isAuthenticated = true
                print("✅ User profile updated successfully")
                
                // Try fetching again to confirm
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                if let profile: User = try? await client
                    .from("profiles")
                    .select()
                    .eq("id", value: userId)
                    .single()
                    .execute()
                    .value {
                    self.currentUser = profile
                }
            } catch {
                print("❌ Error updating user profile: \(error.localizedDescription)")
                print("❌ Full error: \(error)")
            }
        }
    }
    
    private func createUserProfile(user: User) async throws {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        try await client
            .from("profiles")
            .insert(user)
            .execute()
    }
    
    private func getEmailFromUsername(_ username: String) async throws -> String {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        let response: User = try await client
            .from("profiles")
            .select()
            .eq("display_name", value: username)
            .single()
            .execute()
            .value
        
        return response.email
    }
    
    func updateUserProfile(displayName: String?, avatarURL: String?) async throws {
        guard let client = client else {
            throw AuthError.notConfigured
        }
        
        guard var user = currentUser else {
            throw AuthError.userNotFound
        }
        
        if let displayName = displayName {
            user.displayName = displayName
        }
        
        if let avatarURL = avatarURL {
            user.avatarURL = avatarURL
        }
        
        try await client
            .from("profiles")
            .update(user)
            .eq("id", value: user.id)
            .execute()
        
        self.currentUser = user
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
        let filePath = "avatars/\(fileName)"
        
        print("📤 Uploading avatar to: \(filePath)")
        
        // Upload to Supabase Storage
        try await client.storage
            .from("avatars")
            .upload(filePath, data: imageData, options: .init(contentType: "image/jpeg"))
        
        // Get public URL
        let publicURL = try client.storage
            .from("avatars")
            .getPublicURL(path: filePath)
        
        print("✅ Avatar uploaded successfully: \(publicURL)")
        
        // Update user profile with new avatar URL
        try await updateUserProfile(displayName: nil, avatarURL: publicURL.absoluteString)
        
        return publicURL.absoluteString
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
            
            if let fullName = authUser.userMetadata["full_name"] {
                displayName = String(describing: fullName)
            } else if let name = authUser.userMetadata["name"] {
                displayName = String(describing: name)
            } else if let userName = authUser.userMetadata["user_name"] {
                displayName = String(describing: userName)
            }
            
            print("📝 Extracted display name: \(displayName ?? "nil")")
            
            // Extract avatar URL from metadata (try multiple fields)
            var avatarURL: String? = nil
            
            if let picture = authUser.userMetadata["picture"] {
                avatarURL = String(describing: picture)
                print("🔍 Found picture: \(picture)")
            } else if let avatarUrl = authUser.userMetadata["avatar_url"] {
                avatarURL = String(describing: avatarUrl)
                print("🔍 Found avatar_url: \(avatarUrl)")
            }
            
            print("📝 Extracted avatar URL: \(avatarURL ?? "nil")")
            
            // Build update data
            var updateData: [String: String] = [:]
            
            if let name = displayName {
                updateData["display_name"] = name
            }
            
            if let avatar = avatarURL {
                updateData["avatar_url"] = avatar
            }
            
            if !updateData.isEmpty {
                // Update database
                try await client
                    .from("profiles")
                    .update(updateData)
                    .eq("id", value: userId)
                    .execute()
                
                // Update local state
                if let name = displayName {
                    self.currentUser?.displayName = name
                    print("✅ Display name updated to: \(name)")
                }
                
                if let avatar = avatarURL {
                    self.currentUser?.avatarURL = avatar
                    print("✅ Avatar URL updated to: \(avatar)")
                }
            }
        } catch {
            print("❌ Error updating display name: \(error.localizedDescription)")
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
