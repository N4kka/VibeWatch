import Foundation
import Supabase
import Auth
import AuthenticationServices
import RevenueCat

@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    // Supabase configuration (from Secrets.xcconfig -> Info.plist -> Config)
    private let supabaseURL = Config.supabaseURL
    private let supabaseAnonKey = Config.supabaseAnonKey
    private let supabaseFunctionsBaseURL: String = {
        let base = Config.supabaseURL
        guard !base.isEmpty else { return "" }
        return base.replacingOccurrences(of: ".supabase.co", with: ".functions.supabase.co")
    }()

    private(set) var client: Supabase.SupabaseClient?
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isPasswordRecoveryFlowPresented = false
    private var lastRevenueCatUserId: String?
    private let baseCallbackScheme = "com.vibewatch.vibewatchapp"
    
    // Internal flag to track if we are in a temporary recovery session
    // When true, we hide the authenticated state from the UI (Guest Mode)
    // even though the SDK has an active session for password update.
    private var isRecoverySession = false

    // UserDefaults keys for offline persistence
    private let cachedUserKey = "auth_cached_user"
    private let cachedAuthStateKey = "auth_cached_is_authenticated"
    private let expectingPasswordResetKey = "auth_expecting_password_reset"
    private let userDefaults = UserDefaults.standard

    private init() {
        loadCachedAuthState()
        setupClient()
        print("✅ AuthService initialized with real Supabase")
    }
    
    private func setupClient() {
        guard !supabaseURL.isEmpty && supabaseURL != "YOUR_SUPABASE_URL",
              !supabaseAnonKey.isEmpty && supabaseAnonKey != "YOUR_SUPABASE_ANON_KEY" else {
            print("⚠️ Supabase credentials not configured (check Secrets.xcconfig)")
            return
        }

        if supabaseURL.contains("$(") {
            print("⚠️ Supabase URL not resolved (check Secrets.xcconfig)")
            return
        }

        guard let url = URL(string: supabaseURL),
              url.scheme?.hasPrefix("http") == true,
              url.host != nil else {
            print("❌ Invalid Supabase URL (expected https://<project>.supabase.co)")
            return
        }

        client = Supabase.SupabaseClient(supabaseURL: url, supabaseKey: supabaseAnonKey)
        
        // Listen for auth state changes (Reliable way to detect password recovery)
        Task {
            guard let client = client else { return }
            for await event in client.auth.authStateChanges {
                print("🔄 [Auth] Auth event received: \(event.event)")
                
                // Check if we are in a password recovery flow via SDK event OR local expectation
                let isExpectingReset = userDefaults.bool(forKey: expectingPasswordResetKey)
                
                if event.event == .passwordRecovery {
                    print("🔐 [Auth] Password recovery event detected from SDK stream")
                    await MainActor.run {
                        self.isRecoverySession = true // Mask auth state
                        self.isPasswordRecoveryFlowPresented = true
                        // Clear expectation since we handled it
                        self.userDefaults.set(false, forKey: self.expectingPasswordResetKey)
                    }
                } else if event.event == .signedIn && isExpectingReset {
                    // Fallback: If we just signed in and were expecting a reset (PKCE flow often emits signedIn instead of passwordRecovery)
                    print("🔐 [Auth] Signed in while expecting password reset - triggering flow")
                    await MainActor.run {
                        self.isRecoverySession = true // Mask auth state
                        self.isPasswordRecoveryFlowPresented = true
                        // Clear expectation since we handled it
                        self.userDefaults.set(false, forKey: self.expectingPasswordResetKey)
                    }
                }
                
                // Refresh auth state on relevant events
                if [.signedIn, .signedOut, .userUpdated].contains(event.event) {
                    await checkAuthState()
                }
            }
        }

        // Check initial auth state
        Task {
            await checkAuthState()
        }
    }

    // MARK: - Offline Persistence

    /// Load cached authentication state from UserDefaults (for offline support)
    private func loadCachedAuthState() {
        isAuthenticated = userDefaults.bool(forKey: cachedAuthStateKey)

        if let userData = userDefaults.data(forKey: cachedUserKey) {
            do {
                currentUser = try JSONDecoder().decode(User.self, from: userData)
                print("📦 [Auth] Loaded cached user: \(currentUser?.email ?? "unknown")")
                print("   Display name: \(currentUser?.displayName ?? "nil")")
                print("   Is authenticated: \(isAuthenticated)")

                // Sync with RevenueCat if we have a cached user
                if let userId = currentUser?.id {
                    Task {
                        await syncRevenueCatUser(with: userId)
                    }
                }
            } catch {
                print("⚠️ [Auth] Failed to decode cached user: \(error.localizedDescription)")
                currentUser = nil
                isAuthenticated = false
            }
        } else if isAuthenticated {
            // We think we're authenticated but have no cached user - clear the flag
            print("⚠️ [Auth] Authenticated flag set but no cached user found - clearing")
            isAuthenticated = false
            clearCachedAuthState()
        }
    }

    /// Save authentication state to UserDefaults (for offline support)
    private func saveCachedAuthState() {
        userDefaults.set(isAuthenticated, forKey: cachedAuthStateKey)

        if let user = currentUser {
            do {
                let userData = try JSONEncoder().encode(user)
                userDefaults.set(userData, forKey: cachedUserKey)
                print("💾 [Auth] Cached user for offline access: \(user.email)")
            } catch {
                print("⚠️ [Auth] Failed to encode user for caching: \(error.localizedDescription)")
            }
        } else {
            userDefaults.removeObject(forKey: cachedUserKey)
        }
    }

    /// Clear cached authentication state
    private func clearCachedAuthState() {
        userDefaults.removeObject(forKey: cachedUserKey)
        userDefaults.removeObject(forKey: cachedAuthStateKey)
        print("🗑️ [Auth] Cleared cached auth state")
    }
    
    /// Return the current authenticated user (cached)
    func getCurrentUser() async -> User? {
        currentUser
    }
    
    func handleAuthCallback(url: URL) async throws {
        print("🔗 [Auth] Handling callback URL: \(url.absoluteString)")
        
        // Check for explicit errors in the URL (Supabase returns error_description in hash or query)
        if let errorDescription = extractErrorDescription(from: url) {
            print("❌ [Auth] Error detected in callback URL: \(errorDescription)")
            await MainActor.run {
                AppState.shared.showErrorToast = true
                AppState.shared.toastMessage = errorDescription
            }
            return
        }
        
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        // Supabase may return tokens in the fragment; move them into the query so the SDK can parse them
        let normalizedURL = moveFragmentToQueryIfNeeded(url)
        print("🔗 [Auth] Normalized URL: \(normalizedURL.absoluteString)")

        do {
            try await client.auth.session(from: normalizedURL)
            print("✅ [Auth] Session successfully established from callback")
        } catch {
            print("❌ [Auth] Failed to establish session from callback: \(error)")
            // If session fails, likely the link is invalid/expired.
            await MainActor.run {
                AppState.shared.showErrorToast = true
                AppState.shared.toastMessage = "auth.error.invalidLink".localized
            }
            throw error
        }

        if isPasswordRecoveryURL(url) {
            print("🔐 [Auth] Detected password recovery URL - triggering flow")
            await MainActor.run {
                self.isPasswordRecoveryFlowPresented = true
            }
        } else {
            print("ℹ️ [Auth] Not a password recovery URL")
        }

        await checkAuthState()
    }
    
    private func extractErrorDescription(from url: URL) -> String? {
        let items = combinedQueryItems(from: url)
        if let errorDesc = items.first(where: { $0.name == "error_description" })?.value {
            return errorDesc.replacingOccurrences(of: "+", with: " ")
        }
        return nil
    }
    
    // MARK: - Authentication State

    func checkAuthState() async {
        guard let client = client else { return }
        
        // If we are in a recovery flow (detected via expectation or event),
        // effectively "hide" the user from the app UI until the flow completes.
        if isRecoverySession || userDefaults.bool(forKey: expectingPasswordResetKey) {
             print("🔒 [Auth] Hiding auth state due to pending recovery flow")
             self.currentUser = nil
             self.isAuthenticated = false
             return
        }

        do {
            let session = try await client.auth.session
            await fetchUserProfile(userId: session.user.id.uuidString)
        } catch {
            // Network error or session expired
            print("⚠️ [Auth] Session check failed: \(error.localizedDescription)")

            // Check if we have a cached user (offline mode)
            if let cachedUser = currentUser, isAuthenticated {
                print("📱 [Auth] Using cached user for offline access: \(cachedUser.email)")
                // Keep the user logged in with cached data
                // Don't change currentUser or isAuthenticated
                // Sync RevenueCat if we haven't already
                if lastRevenueCatUserId != cachedUser.id {
                    await syncRevenueCatUser(with: cachedUser.id)
                }
                return
            }

            // No cached user, truly not authenticated
            print("❌ [Auth] No active session and no cached user")
            self.currentUser = nil
            self.isAuthenticated = false
            clearCachedAuthState()
            await syncRevenueCatUser(with: nil)
        }
    }
    
    // MARK: - Email/Password Authentication
    
    func signUp(username: String, email: String, password: String) async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)
        
        do {
            print("📝 Attempting to sign up user: \(email)")
            print("🔗 Signup Redirect URL: \(authCallbackURL?.absoluteString ?? "nil")")
            
            // FIX: Pass username as metadata so the DB trigger can use it
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(username)],
                redirectTo: authCallbackURL
            )
            
            let userId = response.user.id.uuidString
            print("✅ Auth user created with ID: \(userId)")
            
            // Check if we have a valid session (email confirmation might be required)
            if response.session == nil {
                 print("ℹ️ Sign up successful but no session returned. Email confirmation likely required.")
                 // Return a temporary user object so the UI can handle the 'success' state,
                 // but do not attempt to fetch/create profile as it will fail RLS.
                 return User(
                    id: userId,
                    email: email,
                    displayName: username,
                    avatarURL: nil
                 )
            }
            
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
                    throw AppAuthError.databaseError
                }
            } else if let user = currentUser, (user.displayName == nil || user.displayName == "") {
                // Profile exists but needs username (Trigger might have failed to copy metadata)
                print("📝 Updating existing profile with username")
                try await updateUserProfile(displayName: username, avatarURL: nil)
            }
            
            print("✅ User created successfully with Supabase")
            
            guard let user = currentUser else {
                throw AppAuthError.userNotFound
            }
            
            // Analytics: Track account creation
            AnalyticsService.shared.logAccountCreated(method: "email")
            AnalyticsService.shared.setUserId(user.id)
            
            return user
        } catch let error as AppAuthError {
            print("❌ AuthError: \(error)")
            ErrorHandler.shared.logOnly(error, context: "Sign up")
            throw error
        } catch {
            print("❌ Unexpected error during signup: \(error)")
            ErrorHandler.shared.logOnly(error, context: "Sign up")
            throw AppAuthError.custom(error.localizedDescription)
        }
    }
    
    func signIn(emailOrUsername: String, password: String) async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)
        
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
            throw AppAuthError.userNotFound
        }
        
        print("✅ User signed in successfully with Supabase")
        
        // Analytics: Track sign in
        AnalyticsService.shared.logSignIn(method: "email")
        AnalyticsService.shared.setUserId(user.id)
        
        return user
    }
    
    func signOut(force: Bool = false) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        try await client.auth.signOut()

        self.currentUser = nil
        self.isAuthenticated = false

        // Clear cached auth state for offline mode
        clearCachedAuthState()

        await syncRevenueCatUser(with: nil, forceReset: force)

        // Analytics: Clear user ID
        AnalyticsService.shared.setUserId(nil)

        // Clear Discovery memory cache
        DiscoveryPersonalizationService.shared.clearMemoryCache()

        print("✅ User signed out successfully")
    }

    func sendPasswordReset(email: String) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        guard let redirectURL = authCallbackURL else {
            print("❌ Invalid auth callback URL")
            throw AppAuthError.invalidResponse
        }
        
        print("🔗 Using redirect URL for password reset: \(redirectURL.absoluteString)")
        
        // Set expectation flag so we know to trigger the UI when the user comes back via deep link
        userDefaults.set(true, forKey: expectingPasswordResetKey)
        
        do {
            try await client.auth.resetPasswordForEmail(
                email,
                redirectTo: redirectURL
            )
            print("📧 Password reset email sent to \(email)")
        } catch {
            // Clear flag if sending failed
            userDefaults.set(false, forKey: expectingPasswordResetKey)
            print("❌ Failed to send password reset email: \(error.localizedDescription)")
            throw AppAuthError.passwordResetFailed
        }
    }
    
    func resendConfirmationEmail(email: String) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        do {
            try await client.auth.resend(email: email, type: .signup)
            print("📧 Confirmation email resent to \(email)")
        } catch {
            print("❌ Failed to resend confirmation email: \(error)")
            throw error
        }
    }
    
    // MARK: - Social Authentication
    
    func signInWithApple() async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)
        
        print("🍎 Starting Apple Sign In...")
        
        // Sign in with Apple OAuth
        try await client.auth.signInWithOAuth(
            provider: .apple,
            redirectTo: authCallbackURL
        )
        
        // Wait for auth to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Check auth state and fetch profile
        await checkAuthState()
        
        guard let user = currentUser else {
            throw AppAuthError.userNotFound
        }
        
        print("✅ Apple Sign In successful")
        return user
    }
    
    func signInWithGoogle() async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)
        
        print("🔍 Starting Google Sign In...")
        
        // Sign in with Google OAuth
        try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: authCallbackURL
        )
        
        // Wait for auth to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Check auth state and fetch profile
        await checkAuthState()
        
        guard let user = currentUser else {
            throw AppAuthError.userNotFound
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
                // Try to fetch with .single() first
                do {
                    return try await client
                        .from("profiles")
                        .select()
                        .eq("id", value: userId)
                        .single()
                        .execute()
                        .value
                } catch {
                    // If .single() fails (e.g., duplicate profiles), fetch array and take first
                    print("⚠️ Single fetch failed (possibly duplicates), trying array fetch...")
                    let profiles: [User] = try await client
                        .from("profiles")
                        .select()
                        .eq("id", value: userId)
                        .order("created_at", ascending: false) // Get most recent first
                        .limit(1)
                        .execute()
                        .value
                    
                    guard let profile = profiles.first else {
                        throw NSError(domain: "AuthService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No profile found"])
                    }
                    
                    print("⚠️ Found \(profiles.count) profile(s) for user. Using most recent.")
                    return profile
                }
            }
            
            do {
                // Attempt 1: Standard Fetch
                print("🔍 Attempting to fetch profile from database...")
                let response = try await performFetch()
                self.currentUser = response
                self.isAuthenticated = true

                // Cache for offline access
                saveCachedAuthState()

                // Register for push notifications now that we have an authenticated user
                NotificationService.shared.registerDeviceToken()

                print("✅ User profile fetched successfully: \(response.email)")
                print("   Display name: \(response.displayName ?? "nil")")
                print("   Avatar URL: \(response.avatarURL ?? "nil")")
                await syncRevenueCatUser(with: userId)
                
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

                    // Cache for offline access
                    saveCachedAuthState()

                    // Register for push notifications now that we have an authenticated user
                    NotificationService.shared.registerDeviceToken()

                    print("✅ User profile fetched after recovery: \(retryResponse.email)")
                    await syncRevenueCatUser(with: userId)
                } catch let retryError {
                    print("❌ Final fetch failed: \(retryError)")
                    print("❌ This will cause 'User not found' error in sign in")
                    // Ensure currentUser is nil so signUp knows to try manual creation
                    self.currentUser = nil
                    await syncRevenueCatUser(with: nil)
                }
            }
        }

    private func syncRevenueCatUser(with userId: String?, forceReset: Bool = false) async {
        if forceReset {
            do {
                _ = try await Purchases.shared.logOut()
                
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Purchases.shared.logOut { _, _ in
                        print("🛑 [RevenueCat] SDK has been reset forcefully.")
                        continuation.resume()
                    }
                }
            } catch {
                print("❌ [RevenueCat] Failed to log out before reset: \(error.localizedDescription)")
            }
            lastRevenueCatUserId = nil
            return
        }
        
        let trimmedId = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedId, !trimmedId.isEmpty {
            guard trimmedId != lastRevenueCatUserId else { return }
            do {
                let result = try await Purchases.shared.logIn(trimmedId)
                lastRevenueCatUserId = trimmedId
                print("💎 [RevenueCat] Logged in as \(result.customerInfo.originalAppUserId)")
            } catch {
                print("❌ [RevenueCat] Failed to log in app user: \(error.localizedDescription)")
            }
        } else {
            guard lastRevenueCatUserId != nil else { return }
            do {
                _ = try await Purchases.shared.logOut()
                print("↩️ [RevenueCat] Logged out app user")
            } catch {
                print("❌ [RevenueCat] Failed to log out app user: \(error.localizedDescription)")
            }
            lastRevenueCatUserId = nil
        }
    }
    
    private func getEmailFromUsername(_ username: String) async throws -> String {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        struct EmailRow: Decodable { let email: String }
        
        func fetchEmail(filter: (PostgrestFilterBuilder) -> PostgrestFilterBuilder) async throws -> String? {
            let rows: [EmailRow] = try await filter(
                client
                    .from("profiles")
                    .select("email")
            )
            .limit(1)
            .execute()
            .value
            return rows.first?.email
        }
        
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🔍 Looking up email for username: '\(normalized)'")
        
        // Try filters in order: exact, case-insensitive, fuzzy
        let likePattern = "%\(normalized)%"
        let filters: [(PostgrestFilterBuilder) -> PostgrestFilterBuilder] = [
            { $0.eq("display_name", value: normalized) },
            { $0.ilike("display_name", pattern: normalized) },
            { $0.ilike("display_name", pattern: likePattern) }
        ]
        
        for filter in filters {
            if let emailFound = try? await fetchEmail(filter: filter) {
                print("✅ Found email for username: \(emailFound)")
                return emailFound
            }
        }
        
        print("❌ Username lookup failed: userNotFound")
        throw AppAuthError.userNotFound
    }
    
    func updateUserProfile(displayName: String?, avatarURL: String?) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        guard var user = currentUser else {
            throw AppAuthError.userNotFound
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
    
    func updatePassword(to newPassword: String) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        do {
            try await client.auth.update(user: UserAttributes(password: newPassword))
            print("🔐 Password updated successfully")
        } catch {
            print("❌ Failed to update password: \(error.localizedDescription)")
            throw AppAuthError.passwordUpdateFailed
        }
    }
    
    func deleteAccountPermanently() async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        // Require an authenticated, non-anonymous user before attempting deletion
        guard isAuthenticated, let userId = currentUser?.id else {
            throw AppAuthError.userNotFound
        }

        // Ensure we have a valid session token to call GoTrue
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            print("❌ [Auth] No active session while deleting account: \(error.localizedDescription)")
            throw AppAuthError.userNotFound
        }
        
        guard let deleteURL = URL(string: "\(supabaseFunctionsBaseURL)/delete-user") else {
            throw AppAuthError.invalidResponse
        }
        
        var request = URLRequest(url: deleteURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse {
            guard 200..<300 ~= httpResponse.statusCode else {
                print("❌ [Auth] Account deletion failed with status: \(httpResponse.statusCode)")
                throw AppAuthError.accountDeletionFailed
            }
        } else {
            throw AppAuthError.accountDeletionFailed
        }
        
        // Attempt to purge profile data
        do {
            try await client
                .from("profiles")
                .delete()
                .eq("id", value: userId)
                .execute()
        } catch {
            print("⚠️ Profile cleanup failed: \(error.localizedDescription)")
        }
        
        // Best-effort: remove other user-scoped data
        let tables = ["user_daily_quota", "user_ai_token_usage", "user_clip_history", "user_clip_signals", "user_preferences"]
        for table in tables {
            do {
                try await client
                    .from(table)
                    .delete()
                    .eq("user_id", value: userId)
                    .execute()
                print("🗑️ Deleted rows from \(table) for user \(userId)")
            } catch {
                print("⚠️ Failed to delete from \(table): \(error.localizedDescription)")
            }
        }
        
        // Clear local state
        self.currentUser = nil
        self.isAuthenticated = false

        // Clear cached auth state for offline mode
        clearCachedAuthState()

        await syncRevenueCatUser(with: nil, forceReset: true)
        await cleanupLocalUserData()
    }

    private func cleanupLocalUserData() async {
        ListManager.shared.resetListsForLoggedOutUser()
        DailyQuotaManager.shared.resetQuota()
        DailyQuotaManager.shared.downgradeToFree()
        ClipQuotaService.shared.resetAll()
        ContentCacheManager.shared.clearAllCaches()
        SQLiteService.shared.resetDatabase()
        
        // Clear any cached auth state
        await AppState.shared.checkAuthState()
    }
    
    func uploadAvatar(imageData: Data) async throws -> String {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw AppAuthError.userNotFound
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
            throw AppAuthError.notConfigured
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
            
            // Build upsert data - must include id and email for creation
            struct ProfileUpsert: Encodable {
                let id: String
                let email: String
                let display_name: String?
                let avatar_url: String?
            }
            
            let profileData = ProfileUpsert(
                id: userId,
                email: authUser.email ?? "",
                display_name: displayName,
                avatar_url: avatarURL
            )
            
            // Upsert (create or update) profile in database
            try await client
                .from("profiles")
                .upsert(profileData)
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

    func upsertDeviceToken(_ token: String, platform: String = "ios") async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        struct DeviceParams: Encodable {
            let p_fcm_token: String
            let p_platform: String
        }

        do {
            try await client
                .rpc(
                    "register_user_device",
                    params: DeviceParams(p_fcm_token: token, p_platform: platform)
                )
                .execute()
        } catch {
            print("❌ Device token RPC failed: \(error)")
            throw AppAuthError.databaseError
        }
    }
    
    private func isPasswordRecoveryURL(_ url: URL) -> Bool {
        let queryItems = combinedQueryItems(from: url)
        
        // Debug: Print all keys found
        let keys = queryItems.map { $0.name }
        print("🔍 [Auth] Callback Params: \(keys)")
        
        let isRecovery = queryItems.contains(where: { item in
            item.name == "type" && item.value == "recovery"
        })
        
        print("🔍 [Auth] Is Recovery: \(isRecovery)")
        return isRecovery
    }

    /// Combine query items from both the query string and the fragment portion (#) to support Supabase OAuth/recovery redirects.
    private func combinedQueryItems(from url: URL) -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query = components?.queryItems {
            items.append(contentsOf: query)
        }

        if let fragment = components?.fragment,
           let fragComponents = URLComponents(string: "?\(fragment)"),
           let fragItems = fragComponents.queryItems {
            items.append(contentsOf: fragItems)
        }

        return items
    }

    /// Supabase sometimes returns tokens in the fragment; this helper moves them into the query string for proper parsing.
    private func moveFragmentToQueryIfNeeded(_ url: URL) -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              !fragment.isEmpty,
              var merged = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        // Merge existing query items with fragment items
        var queryItems = merged.queryItems ?? []
        if let fragComponents = URLComponents(string: "?\(fragment)"),
           let fragItems = fragComponents.queryItems {
            queryItems.append(contentsOf: fragItems)
        }
        merged.fragment = nil
        merged.queryItems = queryItems
        return merged.url ?? url
    }

    /// Show a user-facing message if the recovery link is expired/invalid.
    private func handleRecoveryErrorIfNeeded(from url: URL) {
        let items = combinedQueryItems(from: url)
        let errorCode = items.first(where: { $0.name == "error_code" })?.value
        let isRecovery = items.contains(where: { $0.name == "type" && $0.value == "recovery" })

        if isRecovery || errorCode == "otp_expired" {
            let message = "Email link is invalid or has expired. Please request a new password reset link."
            AppState.shared.toastMessage = message
            AppState.shared.showErrorToast = true
        }
    }

    /// Build the auth callback URL based on current bundle identifier (supports beta/prod)
    private var authCallbackURL: URL? {
        let isBeta = (Bundle.main.bundleIdentifier ?? "").contains(".beta")
        let scheme = isBeta ? "\(baseCallbackScheme).beta" : baseCallbackScheme
        return URL(string: "\(scheme)://auth/callback")
    }
    
    func completeRecovery() async {
        print("✅ [Auth] Completing recovery flow")
        
        // 1. Turn off the "Guest Mode" mask
        await MainActor.run {
            self.isRecoverySession = false
            self.isPasswordRecoveryFlowPresented = false
        }
        
        // 2. Refresh the actual auth state so the UI updates to "Signed In"
        // (Supabase session is already valid from the recovery link)
        await checkAuthState()
    }
    
    /// Update user preferences in database
    func updateUserPreferences(_ user: User) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }
        
        struct ProfileUpdatePayload: Encodable {
            let display_name: String?
            let avatar_url: String?
            let cache_size_preference: String?
            let image_prefetch_option: String?
        }
        
        let payload = ProfileUpdatePayload(
            display_name: user.displayName,
            avatar_url: user.avatarURL,
            cache_size_preference: user.cacheSizePreference.rawValue,
            image_prefetch_option: user.imagePrefetchOption.rawValue
        )
        
        do {
            // Perform update
            try await client
                .from("profiles")
                .update(payload)
                .eq("id", value: user.id)
                .execute()
            
            // Refresh local cache from server to keep consistency
            await fetchUserProfile(userId: user.id)
            await MainActor.run {
                saveCachedAuthState()
            }
            
            print("✅ User preferences updated successfully")
        } catch {
            print("❌ Error updating user preferences: \(error)")
            throw AppAuthError.databaseError
        }
    }
}

enum AppAuthError: LocalizedError {
    case notConfigured
    case invalidResponse
    case userNotFound
    case invalidCredentials
    case networkError
    case databaseError
    case signUpFailed
    case passwordResetFailed
    case passwordUpdateFailed
    case accountDeletionFailed
    case custom(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "auth.error.notConfigured".localized
        case .invalidResponse:
            return "auth.error.invalidResponse".localized
        case .userNotFound:
            return "auth.error.userNotFound".localized
        case .invalidCredentials:
            return "auth.error.invalidCredentials".localized
        case .networkError:
            return "auth.error.networkError".localized
        case .databaseError:
            return "auth.error.databaseError".localized
        case .signUpFailed:
            return "auth.error.signUpFailed".localized
        case .passwordResetFailed:
            return "auth.error.passwordResetFailed".localized
        case .passwordUpdateFailed:
            return "auth.error.passwordUpdateFailed".localized
        case .accountDeletionFailed:
            return "auth.error.accountDeletionFailed".localized
        case .custom(let message):
            return message
        }
    }
}
