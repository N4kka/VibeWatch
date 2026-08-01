import Foundation

// MARK: - UniversalLinks (SPEC v3 §9.4)

/// Le due rotte web che l'app sa aprire: `/@{username}` e `/film/{id}`.
///
/// Il dominio non è ancora deciso (il sito "arriva subito dopo", §9.4): `host` qui sotto è un
/// segnaposto, e deve restare **l'unico posto nel codice** dove il dominio compare. Gli altri due
/// posti stanno fuori dal codice e un test li tiene allineati a questo valore
/// (`UniversalLinksTests.testEntitlementsCombacianoConHost`):
///
///   1. `VibeWatchApp/VibeWatchApp.entitlements` e `VibeWatchAppRelease.entitlements`
///      (`com.apple.developer.associated-domains`, voce `applinks:`);
///   2. il file `apple-app-site-association` in `docs/universal-links/`, che però è
///      indipendente dal dominio per costruzione: elenca percorsi, non host.
///
/// Quando il dominio vero esisterà: cambiare `host`, far girare i test (falliranno finché gli
/// entitlement non seguono), servire l'AASA come descritto in `docs/universal-links/README.md`.
enum UniversalLinks {

    /// SEGNAPOSTO — il dominio vero non è ancora deciso. Vedi il commento in testa.
    static let host = "vibewatch.app"

    /// Una destinazione riconosciuta in un universal link.
    enum Route: Equatable {
        case profile(username: String)
        case film(id: Int)
    }

    /// Riconosce le rotte di §9.4 in un URL. Restituisce `nil` per tutto il resto: un `nil` qui
    /// significa "non è roba nostra" e chi chiama deve lasciar cadere il link, non inventarsi una
    /// destinazione di ripiego — un link sbagliato che apre la home sembrerebbe funzionare.
    static func route(for url: URL) -> Route? {
        // Gli universal link sono sempre https; lo scheme OAuth passa di qui prima di essere
        // riconosciuto altrove, e non deve mai somigliare a una rotta web.
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let urlHost = url.host?.lowercased(), urlHost == host else { return nil }

        // `URL.path` è già percent-decoded. Il trailing slash non è una rotta diversa.
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }

        if path.hasPrefix("/@") {
            // La forma degli username è quella di `UsernameRules` (identica al CHECK del server).
            // Le maiuscole si abbassano invece di rifiutare: `username` è citext sul server,
            // quindi `/@Mario` e `/@mario` sono lo stesso profilo.
            let username = String(path.dropFirst(2)).lowercased()
            guard username.range(of: UsernameRules.pattern, options: .regularExpression) != nil else {
                return nil
            }
            return .profile(username: username)
        }

        let segments = path.split(separator: "/")
        if segments.count == 2, segments[0] == "film",
           let id = Int(segments[1]), id > 0 {
            return .film(id: id)
        }

        return nil
    }
}
