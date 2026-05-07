import Foundation
import Combine

/// Protocol defining the authentication service interface.
/// Enables testability through dependency injection and mocking.
@MainActor
protocol AuthServiceProtocol: AnyObject, ObservableObject {
    // MARK: - Published Properties

    var currentUser: User? { get }
    var isAuthenticated: Bool { get }
    var isPasswordRecoveryFlowPresented: Bool { get set }

    // MARK: - Authentication Methods

    func getCurrentUser() async -> User?
    func checkAuthState() async
    func signUp(username: String, email: String, password: String) async throws -> User
    func signIn(emailOrUsername: String, password: String) async throws -> User
    func signOut(force: Bool) async throws
    func signInWithApple() async throws -> User
    func signInWithGoogle() async throws -> User

    // MARK: - Password Management

    func sendPasswordReset(email: String) async throws
    func updatePassword(to newPassword: String) async throws
    func resendConfirmationEmail(email: String) async throws
    func completeRecovery() async

    // MARK: - Profile Management

    func updateUserProfile(displayName: String?, avatarURL: String?) async throws
    func uploadAvatar(imageData: Data) async throws -> String
    func deleteAccountPermanently() async throws
    func updateUserPreferences(_ user: User) async throws

    // MARK: - Device & Callbacks

    func handleAuthCallback(url: URL) async throws
    func upsertDeviceToken(_ token: String, platform: String) async throws
}
