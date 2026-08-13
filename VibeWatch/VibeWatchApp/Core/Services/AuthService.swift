import Foundation
import Supabase
import Auth
import AuthenticationServices
import CryptoKit
import RevenueCat
import UIKit

@MainActor
class AuthService: AuthServiceProtocol {
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
    /// A chi appartengono i dati che stanno adesso sul device (nil = utente anonimo).
    private let localDataOwnerKey = "auth_local_data_owner_id"
    /// Segna che il seeding una tantum di `localDataOwnerKey` è già avvenuto: senza, chi aggiorna
    /// l'app da una versione precedente sarebbe letto come "dati anonimi" e si vedrebbe cancellare
    /// il proprio device al primo refresh del profilo.
    private let localDataOwnerSeededKey = "auth_local_data_owner_seeded"
    /// L'utente ha appena avviato la creazione di un account: i dati anonimi di questo device
    /// diventano il suo punto di partenza invece di essere buttati.
    private let pendingSignUpMigrationKey = "auth_pending_signup_migration"
    private let userDefaults = UserDefaults.standard

    // Keychain storage for encrypted auth token persistence
    private let keychainStorage = KeychainStorage()

    private init() {
        AuthService._migrateUserDefaultsToKeychain(from: UserDefaults.standard, to: KeychainStorage())
        loadCachedAuthState()
        seedLocalDataOwnerIfNeeded()
        setupClient()
        Logger.info("[Auth] AuthService initialized with real Supabase")
    }

    // MARK: - UserDefaults to Keychain Migration

    /// Migrates cached auth state from UserDefaults to Keychain.
    /// This static overload accepts injected stores to allow unit testing without
    /// triggering the @MainActor singleton (which is not constructible in tests).
    ///
    /// - Parameters:
    ///   - defaults: The UserDefaults instance to read from and clear.
    ///   - keychain: The AuthLocalStorage (Keychain) to write to.
    @discardableResult
    nonisolated static func _migrateUserDefaultsToKeychain(
        from defaults: UserDefaults,
        to keychain: any AuthLocalStorage
    ) -> Bool {
        // Idempotency check: if the trigger key is absent, migration already ran
        guard defaults.object(forKey: "auth_cached_user") != nil else {
            return true
        }

        var migrationFailed = false

        // Migrate auth_cached_user (Data)
        if let userData = defaults.data(forKey: "auth_cached_user") {
            do {
                try keychain.store(key: "auth_cached_user", value: userData)
                defaults.removeObject(forKey: "auth_cached_user")
            } catch {
                Logger.error("[Auth] Keychain migration failed for auth_cached_user: \(error)")
                migrationFailed = true
            }
        }

        // Migrate auth_cached_is_authenticated (Bool as 1-byte Data)
        if !migrationFailed {
            let isAuth = defaults.bool(forKey: "auth_cached_is_authenticated")
            let isAuthData = Data([isAuth ? 1 : 0])
            do {
                try keychain.store(key: "auth_cached_is_authenticated", value: isAuthData)
                defaults.removeObject(forKey: "auth_cached_is_authenticated")
            } catch {
                Logger.error("[Auth] Keychain migration failed for auth_cached_is_authenticated: \(error)")
                migrationFailed = true
            }
        }

        if migrationFailed {
            Logger.warning("[Auth] Keychain migration failed — user will need to re-login")
            // Clear both stores to avoid stale plaintext tokens
            defaults.removeObject(forKey: "auth_cached_user")
            defaults.removeObject(forKey: "auth_cached_is_authenticated")
            try? keychain.remove(key: "auth_cached_user")
            try? keychain.remove(key: "auth_cached_is_authenticated")
            return false
        }

        return true
    }

    private func setupClient() {
        guard !supabaseURL.isEmpty && supabaseURL != "YOUR_SUPABASE_URL",
              !supabaseAnonKey.isEmpty && supabaseAnonKey != "YOUR_SUPABASE_ANON_KEY" else {
            Logger.warning("[Auth] Supabase credentials not configured (check Secrets.xcconfig)")
            return
        }

        if supabaseURL.contains("$(") {
            Logger.warning("[Auth] Supabase URL not resolved (check Secrets.xcconfig)")
            return
        }

        guard let url = URL(string: supabaseURL),
              url.scheme?.hasPrefix("http") == true,
              url.host != nil else {
            Logger.error("[Auth] Invalid Supabase URL (expected https://<project>.supabase.co)")
            return
        }

        let options = SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(storage: keychainStorage)
        )
        client = Supabase.SupabaseClient(supabaseURL: url, supabaseKey: supabaseAnonKey, options: options)

        // Listen for auth state changes (Reliable way to detect password recovery)
        Task {
            guard let client = client else { return }
            for await event in client.auth.authStateChanges {
                Logger.debug("[Auth] Auth event received: \(event.event)")

                // Check if we are in a password recovery flow via SDK event OR local expectation
                let isExpectingReset = userDefaults.bool(forKey: expectingPasswordResetKey)

                if event.event == .passwordRecovery {
                    Logger.debug("[Auth] Password recovery event detected from SDK stream")
                    await MainActor.run {
                        self.isRecoverySession = true // Mask auth state
                        self.isPasswordRecoveryFlowPresented = true
                        // Clear expectation since we handled it
                        self.userDefaults.set(false, forKey: self.expectingPasswordResetKey)
                    }
                } else if event.event == .signedIn && isExpectingReset {
                    // Fallback: If we just signed in and were expecting a reset (PKCE flow often emits signedIn instead of passwordRecovery)
                    Logger.debug("[Auth] Signed in while expecting password reset - triggering flow")
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

    /// Load cached authentication state from Keychain (for offline support)
    private func loadCachedAuthState() {
        // Read isAuthenticated from Keychain (1-byte Bool encoding)
        if let isAuthData = try? keychainStorage.retrieve(key: cachedAuthStateKey),
           let byte = isAuthData.first {
            isAuthenticated = byte != 0
        } else {
            isAuthenticated = false
        }

        if let userData = try? keychainStorage.retrieve(key: cachedUserKey) {
            do {
                currentUser = try JSONDecoder().decode(User.self, from: userData)
                // Phase 5: Use Logger for sensitive data (email sanitization)
                Logger.info("[Auth] Loaded cached user: \(currentUser?.id.prefix(8) ?? "unknown")...")
                Logger.debug("[Auth] Display name: \(currentUser?.displayName ?? "nil")")
                Logger.debug("[Auth] Is authenticated: \(isAuthenticated)")

                // Sync with RevenueCat if we have a cached user
                if let userId = currentUser?.id {
                    Task {
                        await syncRevenueCatUser(with: userId)
                    }
                }
            } catch {
                Logger.warning("[Auth] Failed to decode cached user: \(error.localizedDescription)")
                currentUser = nil
                isAuthenticated = false
            }
        } else if isAuthenticated {
            // We think we're authenticated but have no cached user - clear the flag
            Logger.warning("[Auth] Authenticated flag set but no cached user found - clearing")
            isAuthenticated = false
            clearCachedAuthState()
        }
    }

    /// Save authentication state to Keychain (for offline support)
    private func saveCachedAuthState() {
        // Store isAuthenticated as 1-byte Data in Keychain
        let isAuthData = Data([isAuthenticated ? 1 : 0])
        try? keychainStorage.store(key: cachedAuthStateKey, value: isAuthData)

        if let user = currentUser {
            do {
                let userData = try JSONEncoder().encode(user)
                try? keychainStorage.store(key: cachedUserKey, value: userData)
                // Phase 5: Use Logger for sensitive data (email sanitization)
                Logger.info("[Auth] Cached user for offline access: \(user.id.prefix(8))...")
            } catch {
                Logger.warning("[Auth] Failed to encode user for caching: \(error.localizedDescription)")
            }
        } else {
            try? keychainStorage.remove(key: cachedUserKey)
        }
    }

    // MARK: - Proprietà dei dati locali

    /// Prima installazione della versione che tiene traccia del proprietario dei dati: chi era già
    /// loggato adotta i propri dati, chi non lo era resta anonimo. Gira una sola volta, all'avvio
    /// e fuori da qualsiasi flusso di login, così un utente aggiornato non finisce nel ramo
    /// "dati di un altro account" e non si vede azzerare il device.
    private func seedLocalDataOwnerIfNeeded() {
        guard !userDefaults.bool(forKey: localDataOwnerSeededKey) else { return }

        // Il Keychain non risponde quando l'app parte in background prima del primo sblocco dopo
        // un riavvio. Lì "nessun utente in cache" non vuol dire "device anonimo": si rimanda al
        // prossimo avvio invece di registrare una risposta che non abbiamo.
        do {
            _ = try keychainStorage.retrieve(key: cachedUserKey)
        } catch {
            Logger.warning("[Auth] Keychain non leggibile all'avvio: seeding della proprietà dei dati rimandato")
            return
        }

        userDefaults.set(true, forKey: localDataOwnerSeededKey)

        if isAuthenticated, let userId = currentUser?.id {
            userDefaults.set(userId, forKey: localDataOwnerKey)
            Logger.debug("[Auth] Local data ownership seeded for \(userId.prefix(8))...")
        } else {
            userDefaults.removeObject(forKey: localDataOwnerKey)
        }
    }

    /// Decide se i dati già presenti sul device possono restare a `userId`.
    ///
    /// Tre casi, in ordine:
    /// 1. sono già i suoi → non si tocca niente;
    /// 2. sono di un altro account → si cancella tutto, o l'account che entra si troverebbe in
    ///    casa cronologia, liste e gusti di chi c'era prima (e li ri-caricherebbe sul server come
    ///    propri al primo sync);
    /// 3. sono anonimi → si cancellano, tranne quando questo login *è* la nascita dell'account:
    ///    lì la continuità è il comportamento voluto, l'utente si porta dentro quello che ha
    ///    guardato e cercato da anonimo.
    private func reconcileLocalDataOwnership(for userId: String) async {
        // Nessun seeding riuscito prima di questo login: di chi siano i dati sul device non lo
        // sappiamo, e per un utente che era già dentro cancellarli sarebbe una perdita secca.
        // Si adotta e da qui in poi la traccia c'è.
        guard userDefaults.bool(forKey: localDataOwnerSeededKey) else {
            userDefaults.set(true, forKey: localDataOwnerSeededKey)
            userDefaults.set(userId, forKey: localDataOwnerKey)
            userDefaults.set(false, forKey: pendingSignUpMigrationKey)
            return
        }

        let owner = userDefaults.string(forKey: localDataOwnerKey)
        guard owner != userId else { return }

        let pendingSignUp = userDefaults.bool(forKey: pendingSignUpMigrationKey)
        userDefaults.set(false, forKey: pendingSignUpMigrationKey)

        let isNewAccount = pendingSignUp ? true : await isFreshlyCreatedAccount()
        if owner == nil, isNewAccount {
            Logger.info("[Auth] Nuovo account da utente anonimo: i dati locali restano e passano a \(userId.prefix(8))...")
            // Restare sul device non basta: le righe sono intestate all'id del device e ogni
            // lettura filtra per l'utente loggato. Vanno riassegnate adesso, prima che il sync
            // parta, o il nuovo account nascerebbe con le liste vuote.
            await ListManager.shared.adoptAnonymousLocalData(newOwnerId: userId)
            userDefaults.set(userId, forKey: localDataOwnerKey)
            return
        }

        Logger.info("[Auth] I dati locali sono di \(owner?.prefix(8) ?? "un utente anonimo") — reset prima di entrare come \(userId.prefix(8))...")
        await LocalDataResetService.shared.wipeUserScopedData()
        userDefaults.set(userId, forKey: localDataOwnerKey)
    }

    /// Un account creato in questo stesso momento. Copre il "Continua con Google/Apple" che di
    /// fatto registra: lì non c'è un pulsante di registrazione da cui dedurre l'intenzione. La
    /// finestra è stretta apposta — su un secondo device, dove i dati locali sono di una sessione
    /// anonima diversa, due minuti dopo la registrazione altrove non è un caso da assecondare.
    private func isFreshlyCreatedAccount() async -> Bool {
        guard let client = client,
              let session = try? await client.auth.session else { return false }
        return Date().timeIntervalSince(session.user.createdAt) < 120
    }

    /// Clear cached authentication state
    private func clearCachedAuthState() {
        try? keychainStorage.remove(key: cachedUserKey)
        try? keychainStorage.remove(key: cachedAuthStateKey)
        Logger.debug("[Auth] Cleared cached auth state")
    }

    /// Return the current authenticated user (cached)
    func getCurrentUser() async -> User? {
        currentUser
    }

    func handleAuthCallback(url: URL) async throws {
        Logger.debug("[Auth] Handling callback URL: \(url.absoluteString)")

        // Check for explicit errors in the URL (Supabase returns error_description in hash or query)
        if let errorDescription = extractErrorDescription(from: url) {
            Logger.error("[Auth] Error detected in callback URL: \(errorDescription)")
            await MainActor.run {
                ToastCenter.shared.show(error: errorDescription)
            }
            return
        }

        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        // Supabase may return tokens in the fragment; move them into the query so the SDK can parse them
        let normalizedURL = moveFragmentToQueryIfNeeded(url)
        Logger.debug("[Auth] Normalized URL: \(normalizedURL.absoluteString)")

        do {
            try await client.auth.session(from: normalizedURL)
            Logger.info("[Auth] Session successfully established from callback")
        } catch {
            Logger.error("[Auth] Failed to establish session from callback: \(error)")
            // If session fails, likely the link is invalid/expired.
            await MainActor.run {
                ToastCenter.shared.show(error: "auth.error.invalidLink".localized)
            }
            throw error
        }

        if isPasswordRecoveryURL(url) {
            Logger.debug("[Auth] Detected password recovery URL - triggering flow")
            await MainActor.run {
                self.isPasswordRecoveryFlowPresented = true
            }
        } else {
            Logger.debug("[Auth] Not a password recovery URL")
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
             Logger.debug("[Auth] Hiding auth state due to pending recovery flow")
             self.currentUser = nil
             self.isAuthenticated = false
             return
        }

        do {
            let session = try await client.auth.session
            await fetchUserProfile(userId: session.user.id.uuidString)
        } catch {
            // Network error or session expired
            Logger.warning("[Auth] Session check failed: \(error.localizedDescription)")

            // Sessione rifiutata dal server (o assente): restare "loggati" con la cache
            // Keychain è una bugia — ogni SELECT sotto RLS torna vuota e il primo INSERT
            // muore con "new row violates row-level security policy" (l'import da
            // TestFlight con la sessione ferma da gennaio). Qui si pulisce e basta:
            // niente wipe del DB locale, un re-login con lo stesso account riparte
            // dallo specchio che c'è.
            if isSessionDefinitivelyInvalid(error) {
                Logger.error("[Auth] Session rejected by server — clearing cached auth state, sign-in required")
                self.currentUser = nil
                self.isAuthenticated = false
                clearCachedAuthState()
                await syncRevenueCatUser(with: nil)
                return
            }

            // Check if we have a cached user (offline mode)
            if let cachedUser = currentUser, isAuthenticated {
                Logger.debug("[Auth] Using cached user for offline access: \(cachedUser.id.prefix(8))...")
                // Keep the user logged in with cached data
                // Don't change currentUser or isAuthenticated
                // Sync RevenueCat if we haven't already
                if lastRevenueCatUserId != cachedUser.id {
                    await syncRevenueCatUser(with: cachedUser.id)
                }
                return
            }

            // No cached user, truly not authenticated
            Logger.error("[Auth] No active session and no cached user")
            self.currentUser = nil
            self.isAuthenticated = false
            clearCachedAuthState()
            await syncRevenueCatUser(with: nil)
        }
    }

    /// Distingue "sono offline" da "il server ha rifiutato la sessione". Gli errori di
    /// trasporto (URLError) mantengono la cache offline com'è sempre stato; un AuthError
    /// locale (`sessionMissing`) o una risposta 4xx del GoTrue (refresh token revocato,
    /// scaduto, riusato) sono definitivi. Un 5xx è un inciampo del server: non butta
    /// fuori nessuno.
    private func isSessionDefinitivelyInvalid(_ error: Error) -> Bool {
        if error is URLError { return false }
        if (error as NSError).domain == NSURLErrorDomain { return false }
        guard let authError = error as? AuthError else { return false }
        if case .api(_, _, _, let response) = authError {
            return (400..<500).contains(response.statusCode)
        }
        return true
    }

    // MARK: - Email/Password Authentication

    func signUp(username: String, email: String, password: String) async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)

        // Un anonimo che si registra si porta dentro quello che ha già fatto su questo device.
        // Il flag serve perché fra qui e il primo profilo può passare una conferma via email:
        // quando l'utente torna dal deep link, la sola data di creazione non basterebbe più.
        userDefaults.set(true, forKey: pendingSignUpMigrationKey)

        do {
            Logger.debug("[Auth] Attempting to sign up user: [REDACTED]")
            Logger.debug("[Auth] Signup Redirect URL: \(authCallbackURL?.absoluteString ?? "nil")")

            // FIX: Pass username as metadata so the DB trigger can use it
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(username)],
                redirectTo: authCallbackURL
            )

            let userId = response.user.id.uuidString
            Logger.info("[Auth] Auth user created with ID: \(userId.prefix(8))...")

            // Check if we have a valid session (email confirmation might be required)
            if response.session == nil {
                 Logger.debug("[Auth] Sign up successful but no session returned. Email confirmation likely required.")
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
                Logger.warning("[Auth] Trigger didn't create profile, creating manually...")
                let newUser = User(
                    id: userId,
                    email: email,
                    displayName: username,
                    avatarURL: nil
                )

                do {
                    // Upsert the profile
                    try await updateUserProfileDirectly(user: newUser)
                    Logger.info("[Auth] Profile created manually successfully")

                    self.currentUser = newUser
                    self.isAuthenticated = true
                } catch {
                    Logger.error("[Auth] Error creating profile manually: \(error)")
                    throw AppAuthError.databaseError
                }
            } else if let user = currentUser, (user.displayName == nil || user.displayName == "") {
                // Profile exists but needs username (Trigger might have failed to copy metadata)
                Logger.debug("[Auth] Updating existing profile with username")
                try await updateUserProfile(displayName: username, avatarURL: nil)
            }

            Logger.info("[Auth] User created successfully with Supabase")

            guard let user = currentUser else {
                throw AppAuthError.userNotFound
            }

            // Analytics: Track account creation
            AnalyticsService.shared.logAccountCreated(method: "email")
            AnalyticsService.shared.setUserId(user.id)

            return user
        } catch let error as AppAuthError {
            Logger.error("[Auth] AuthError: \(error)")
            ErrorHandler.shared.logOnly(error, context: "Sign up")
            throw error
        } catch {
            Logger.error("[Auth] Unexpected error during signup: \(error)")
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
        // Una registrazione fallita non deve lasciare in giro il permesso di migrare: qui si entra
        // in un account che esiste già, i dati anonimi del device non lo riguardano.
        userDefaults.set(false, forKey: pendingSignUpMigrationKey)

        // Email diretta a GoTrue; username alla Edge Function, che fa risoluzione e
        // autenticazione in un colpo solo: l'email non lascia mai il server senza la password
        // giusta. La strada vecchia (leggere profiles.email dal client, per giunta con un ilike
        // su display_name) era un endpoint di raccolta indirizzi, e la RLS la bloccava comunque.
        let userId: String
        if emailOrUsername.contains("@") {
            let response = try await client.auth.signIn(
                email: emailOrUsername,
                password: password
            )
            userId = response.user.id.uuidString
        } else {
            let session = try await signInWithUsername(emailOrUsername, password: password)
            userId = session.user.id.uuidString
        }

        // Fetch user profile
        await fetchUserProfile(userId: userId)

        guard let user = currentUser else {
            throw AppAuthError.userNotFound
        }

        Logger.info("[Auth] User signed in successfully with Supabase")

        // Analytics: Track sign in
        AnalyticsService.shared.logSignIn(method: "email")
        AnalyticsService.shared.setUserId(user.id)

        return user
    }

    func signOut(force: Bool = false) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        // Flush local edits while the session is still valid: signing out invalidates the token,
        // and cleanupLocalUserData() below wipes the local database. Best effort and bounded —
        // a slow or offline network must not trap the user in a half-signed-out state, and a
        // forced sign-out (invalid session) has no usable token to push with anyway.
        if !force {
            await withTimeout(seconds: 5) {
                await SyncEngine.shared.pushPendingChanges()
            }
        }

        try await client.auth.signOut()

        self.currentUser = nil
        self.isAuthenticated = false

        // Clear cached auth state for offline mode
        clearCachedAuthState()

        await syncRevenueCatUser(with: nil, forceReset: force)

        // Analytics: Clear user ID
        AnalyticsService.shared.setUserId(nil)

        // The local SQLite store is not scoped per account, so leaving it in place let the next
        // user to sign in on this device read the previous one's lists, history and preferences —
        // and re-upload them under their own id on the next sync. Deleting an account already
        // went through this cleanup; signing out has to do the same.
        await cleanupLocalUserData()

        Logger.info("[Auth] User signed out successfully")
    }

    /// Run `operation`, giving up after `seconds`. Used where a slow network must not block
    /// a user-initiated action that has to complete regardless.
    private func withTimeout(seconds: Double, operation: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    func sendPasswordReset(email: String) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        guard let redirectURL = authCallbackURL else {
            Logger.error("[Auth] Invalid auth callback URL")
            throw AppAuthError.invalidResponse
        }

        Logger.debug("[Auth] Using redirect URL for password reset: \(redirectURL.absoluteString)")

        // Set expectation flag so we know to trigger the UI when the user comes back via deep link
        userDefaults.set(true, forKey: expectingPasswordResetKey)

        do {
            try await client.auth.resetPasswordForEmail(
                email,
                redirectTo: redirectURL
            )
            Logger.info("[Auth] Sending password reset email")
        } catch {
            // Clear flag if sending failed
            userDefaults.set(false, forKey: expectingPasswordResetKey)
            Logger.error("[Auth] Failed to send password reset email: \(error.localizedDescription)")
            throw AppAuthError.passwordResetFailed
        }
    }

    func resendConfirmationEmail(email: String) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        do {
            try await client.auth.resend(email: email, type: .signup)
            Logger.info("[Auth] Confirmation email resent")
        } catch {
            Logger.error("[Auth] Failed to resend confirmation email: \(error)")
            throw error
        }
    }

    // MARK: - Social Authentication

    private let appleSignInCoordinator = AppleSignInCoordinator()

    func signInWithApple(intent: AuthFlowIntent = .signIn) async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)
        userDefaults.set(intent == .signUp, forKey: pendingSignUpMigrationKey)

        Logger.debug("[Auth] Starting native Apple Sign In...")

        // Flusso nativo (ASAuthorizationController + signInWithIdToken) invece dell'OAuth web:
        // quello passava dallo scambio code↔secret lato Supabase, che richiede un client secret
        // della Services ID rinnovato ogni 6 mesi ("Unable to exchange external code" quando
        // scade). L'id token nativo si verifica contro le chiavi pubbliche di Apple.
        let (credential, nonce) = try await appleSignInCoordinator.requestCredential()

        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            Logger.error("[Auth] Apple credential missing identity token")
            throw AppAuthError.invalidResponse
        }

        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )

        await fetchUserProfile(userId: session.user.id.uuidString)

        // Apple fornisce nome e cognome solo alla primissima autorizzazione: se il profilo è
        // ancora senza display name questa è l'unica occasione per salvarlo.
        if let fullName = credential.fullName {
            let name = PersonNameComponentsFormatter().string(from: fullName)
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, (currentUser?.displayName ?? "").isEmpty {
                try? await updateUserProfile(displayName: name, avatarURL: nil)
            }
        }

        guard let user = currentUser else {
            throw AppAuthError.userNotFound
        }

        AnalyticsService.shared.logSignIn(method: "apple")
        AnalyticsService.shared.setUserId(user.id)

        Logger.info("[Auth] Apple Sign In successful")
        return user
    }

    func signInWithGoogle(intent: AuthFlowIntent = .signIn) async throws -> User {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        // Clear reset expectation since this is an explicit action
        userDefaults.set(false, forKey: expectingPasswordResetKey)
        userDefaults.set(intent == .signUp, forKey: pendingSignUpMigrationKey)

        Logger.debug("[Auth] Starting Google Sign In...")

        // prompt=select_account: senza, Google riusa la sessione del browser e non lascia
        // scegliere tra più account.
        try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: authCallbackURL,
            queryParams: [(name: "prompt", value: "select_account")]
        )

        // Wait for auth to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Check auth state and fetch profile
        await checkAuthState()

        guard let user = currentUser else {
            throw AppAuthError.userNotFound
        }

        AnalyticsService.shared.logSignIn(method: "google")
        AnalyticsService.shared.setUserId(user.id)

        Logger.info("[Auth] Google Sign In successful")
        return user
    }


    // MARK: - User Profile Management
    private func fetchUserProfile(userId: String) async {
            guard let client = client else {
                Logger.error("[Auth] Client not configured in fetchUserProfile")
                return
            }

            // Prima di rendere visibile l'utente: questo è l'unico punto attraversato da ogni
            // percorso di autenticazione (email, username, Apple, Google, ripristino sessione,
            // deep link). Metterlo nei singoli metodi avrebbe lasciato scoperto l'OAuth, dove la
            // sessione arriva dallo stream authStateChanges e non dal valore di ritorno.
            await reconcileLocalDataOwnership(for: userId)

            Logger.debug("[Auth] Fetching profile for user ID: \(userId.prefix(8))...")

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
                    Logger.warning("[Auth] Single fetch failed (possibly duplicates), trying array fetch...")
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

                    Logger.warning("[Auth] Found \(profiles.count) profile(s) for user. Using most recent.")
                    return profile
                }
            }

            do {
                // Attempt 1: Standard Fetch
                Logger.debug("[Auth] Attempting to fetch profile from database...")
                let response = try await performFetch()
                self.currentUser = response
                self.isAuthenticated = true

                // Cache for offline access
                saveCachedAuthState()

                // Register for push notifications now that we have an authenticated user
                NotificationService.shared.registerDeviceToken()

                Logger.info("[Auth] User profile fetched successfully for user: \(response.id.prefix(8))...")
                Logger.debug("[Auth] Display name: \(response.displayName ?? "nil")")
                Logger.debug("[Auth] Avatar URL: \(response.avatarURL ?? "nil")")
                await syncRevenueCatUser(with: userId)

                if response.displayName == nil || response.displayName?.isEmpty == true {
                    await updateDisplayNameFromMetadata(userId: userId)
                }
            } catch let fetchError {
                Logger.error("[Auth] First fetch failed: \(fetchError)")
                Logger.warning("[Auth] Attempting metadata sync/recovery...")

                // Attempt 2: Run the metadata sync to fix missing display names
                await updateDisplayNameFromMetadata(userId: userId)

                // Attempt 3: Try fetching ONE MORE TIME after the sync
                do {
                    Logger.debug("[Auth] Retrying profile fetch after metadata sync...")
                    let retryResponse = try await performFetch()
                    self.currentUser = retryResponse
                    self.isAuthenticated = true

                    // Cache for offline access
                    saveCachedAuthState()

                    // Register for push notifications now that we have an authenticated user
                    NotificationService.shared.registerDeviceToken()

                    Logger.info("[Auth] User profile fetched after recovery: \(retryResponse.id.prefix(8))...")
                    await syncRevenueCatUser(with: userId)
                } catch let retryError {
                    Logger.error("[Auth] Final fetch failed: \(retryError)")
                    Logger.error("[Auth] This will cause 'User not found' error in sign in")
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
                        Logger.debug("[RevenueCat] SDK has been reset forcefully.")
                        continuation.resume()
                    }
                }
            } catch {
                Logger.error("[RevenueCat] Failed to log out before reset: \(error.localizedDescription)")
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
                Logger.info("[RevenueCat] Logged in as \(result.customerInfo.originalAppUserId.prefix(8))...")
            } catch {
                Logger.error("[RevenueCat] Failed to log in app user: \(error.localizedDescription)")
            }
        } else {
            guard lastRevenueCatUserId != nil else { return }
            do {
                _ = try await Purchases.shared.logOut()
                Logger.debug("[RevenueCat] Logged out app user")
            } catch {
                Logger.error("[RevenueCat] Failed to log out app user: \(error.localizedDescription)")
            }
            lastRevenueCatUserId = nil
        }
    }

    /// SPEC v3 §3.7 — il login con username, tutto server-side.
    ///
    /// La Edge Function risolve username → email e chiama GoTrue **nella stessa richiesta**:
    /// l'email non passa mai dal client prima dell'autenticazione. Ogni fallimento di
    /// credenziali risponde `invalid_credentials`, identico per username inesistente e password
    /// sbagliata — distinguerli sarebbe un oracolo sugli username, quindi anche qui non si
    /// distingue. Il 429 invece si dice: "riprova più tardi" non rivela niente.
    private func signInWithUsername(_ username: String, password: String) async throws -> Session {
        guard let client = client, let baseURL = URL(string: Config.supabaseURL) else {
            throw AppAuthError.notConfigured
        }

        let url = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("login-with-username")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if Config.supabaseAnonKey.hasPrefix("eyJ") {
            // Come in callRPC: la legacy anon key è un JWT e vale come Bearer; le publishable
            // (sb_publishable_...) no, e il gateway le rifiuterebbe.
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": username, "password": password])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppAuthError.networkError
        }
        guard http.statusCode != 429 else {
            throw AppAuthError.custom("auth.error.tooManyAttempts".localized)
        }
        guard http.statusCode == 200 else {
            throw AppAuthError.invalidCredentials
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            // Un 200 illeggibile è un errore, non delle credenziali sbagliate (la lezione di
            // username_available).
            throw AppAuthError.invalidResponse
        }

        // La sessione diventa quella del client Supabase: da qui in poi il percorso è identico
        // al login con email.
        return try await client.auth.setSession(
            accessToken: accessToken, refreshToken: refreshToken)
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

        Logger.debug("[Auth] Updating profile for user \(user.id.prefix(8))... with data: \(updateData)")

        try await client
            .from("profiles")
            .update(updateData)
            .eq("id", value: user.id)
            .execute()

        self.currentUser = user
        Logger.info("[Auth] Profile updated successfully in database")
    }

    func updatePassword(to newPassword: String) async throws {
        guard let client = client else {
            throw AppAuthError.notConfigured
        }

        do {
            try await client.auth.update(user: UserAttributes(password: newPassword))
            Logger.debug("[Auth] Password updated successfully")
        } catch {
            Logger.error("[Auth] Failed to update password: \(error.localizedDescription)")
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
            Logger.error("[Auth] No active session while deleting account: \(error.localizedDescription)")
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
                Logger.error("[Auth] Account deletion failed with status: \(httpResponse.statusCode)")
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
            Logger.warning("[Auth] Profile cleanup failed: \(error.localizedDescription)")
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
                Logger.debug("[Auth] Deleted rows from \(table) for user \(userId.prefix(8))...")
            } catch {
                Logger.warning("[Auth] Failed to delete from \(table): \(error.localizedDescription)")
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
        // Il device torna anonimo: nessun account possiede più quello che c'è qui sopra.
        userDefaults.removeObject(forKey: localDataOwnerKey)
        userDefaults.set(false, forKey: pendingSignUpMigrationKey)

        await LocalDataResetService.shared.wipeUserScopedData()

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

        Logger.debug("[Auth] Uploading avatar: \(fileName)")

        do {
            // Upload to Supabase Storage
            try await client.storage
                .from("avatars")
                .upload(fileName, data: imageData, options: .init(contentType: "image/jpeg", upsert: true))

            Logger.info("[Auth] Avatar file uploaded to storage")

            // Get public URL
            let publicURL = try client.storage
                .from("avatars")
                .getPublicURL(path: fileName)

            Logger.info("[Auth] Avatar public URL generated: \(publicURL)")

            // Update user profile with new avatar URL
            try await updateUserProfile(displayName: nil, avatarURL: publicURL.absoluteString)

            Logger.info("[Auth] Avatar upload complete and profile updated")

            return publicURL.absoluteString
        } catch {
            Logger.error("[Auth] Error uploading avatar: \(error)")
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
            Logger.debug("[Auth] User metadata: \(authUser.userMetadata)")

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

            Logger.debug("[Auth] Extracted display name: \(displayName ?? "nil")")

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
            Logger.info("[Auth] Synced profile from metadata")

        } catch {
            Logger.error("[Auth] Error syncing from metadata: \(error.localizedDescription)")
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
            Logger.error("[Auth] Device token RPC failed: \(error)")
            throw AppAuthError.databaseError
        }
    }

    private func isPasswordRecoveryURL(_ url: URL) -> Bool {
        // Debug: Print all keys found
        let keys = combinedQueryItems(from: url).map { $0.name }
        Logger.debug("[Auth] Callback Params: \(keys)")

        let isRecovery = AuthCallbackURLParser.isPasswordRecovery(url)
        Logger.debug("[Auth] Is Recovery: \(isRecovery)")
        return isRecovery
    }

    /// Combine query items from both the query string and the fragment portion (#) to support Supabase OAuth/recovery redirects.
    private func combinedQueryItems(from url: URL) -> [URLQueryItem] {
        AuthCallbackURLParser.combinedQueryItems(from: url)
    }

    /// Supabase sometimes returns tokens in the fragment; this helper moves them into the query string for proper parsing.
    private func moveFragmentToQueryIfNeeded(_ url: URL) -> URL {
        AuthCallbackURLParser.moveFragmentToQueryIfNeeded(url)
    }

    /// Show a user-facing message if the recovery link is expired/invalid.
    private func handleRecoveryErrorIfNeeded(from url: URL) {
        if AuthCallbackURLParser.shouldShowRecoveryError(from: url) {
            ToastCenter.shared.show(error: "auth.error.recoveryLinkExpired".localized)
        }
    }

    /// Build the auth callback URL based on current bundle identifier (supports beta/prod)
    private var authCallbackURL: URL? {
        let isBeta = (Bundle.main.bundleIdentifier ?? "").contains(".beta")
        let scheme = isBeta ? "\(baseCallbackScheme).beta" : baseCallbackScheme
        return URL(string: "\(scheme)://auth/callback")
    }

    func completeRecovery() async {
        Logger.info("[Auth] Completing recovery flow")

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

            Logger.info("[Auth] User preferences updated successfully")
        } catch {
            Logger.error("[Auth] Error updating user preferences: \(error)")
            throw AppAuthError.databaseError
        }
    }
}

// MARK: - Native Sign in with Apple

/// Esegue il flusso nativo di Sign in with Apple e restituisce la credenziale insieme al
/// nonce raw da passare a Supabase (nella richiesta ad Apple viaggia il suo SHA-256).
@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                    ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func requestCredential() async throws -> (credential: ASAuthorizationAppleIDCredential, nonce: String) {
        let rawNonce = Self.randomNonceString()

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(rawNonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        let credential = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
            self.continuation = continuation
            controller.performRequests()
        }
        return (credential, rawNonce)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation?.resume(returning: credential)
        } else {
            continuation?.resume(throwing: AppAuthError.invalidResponse)
        }
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            // L'annullamento non è un errore da mostrare: le view lo filtrano come
            // CancellationError.
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else {
            // SecRandom non deve fallire; se succede, un nonce da UUID resta imprevedibile.
            return UUID().uuidString + UUID().uuidString
        }
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
