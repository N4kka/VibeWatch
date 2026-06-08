import Foundation
import Combine

/// Role-protocol ristretto (interface segregation) con il solo stato auth che serve a
/// `ListManager`. Consente di iniettare un'auth mock nei test senza dover stubbare l'intera
/// `AuthServiceProtocol`.
@MainActor
protocol AuthStatusProviding: AnyObject {
    var currentUser: User? { get }
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> { get }
}

extension AuthService: AuthStatusProviding {
    /// `currentUser` è già esposto da AuthService.
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> {
        $isAuthenticated.eraseToAnyPublisher()
    }
}
