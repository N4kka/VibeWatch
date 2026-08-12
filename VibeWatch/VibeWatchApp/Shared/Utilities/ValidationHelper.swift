import Foundation

/// La politica della password vive qui e in un solo posto: Supabase rifiuta lato server ciò che
/// non la rispetta (min 8, minuscola, maiuscola, cifra e simbolo), e una regola scritta due volte
/// è una regola che prima o poi diverge — fino a mandare l'utente contro un errore del server
/// dopo che il client gli aveva detto di sì.
enum PasswordPolicy {
    static let minLength = 8

    /// Le verifiche, nell'ordine in cui si mostrano. La chiave è quella localizzata.
    enum Rule: String, CaseIterable {
        case length = "auth.pwRule.length"
        case uppercase = "auth.pwRule.uppercase"
        case lowercase = "auth.pwRule.lowercase"
        case number = "auth.pwRule.number"
        case symbol = "auth.pwRule.symbol"

        func isSatisfied(by password: String) -> Bool {
            switch self {
            case .length:
                return password.count >= PasswordPolicy.minLength
            case .uppercase:
                return password.range(of: "[A-Z]", options: .regularExpression) != nil
            case .lowercase:
                return password.range(of: "[a-z]", options: .regularExpression) != nil
            case .number:
                return password.range(of: "[0-9]", options: .regularExpression) != nil
            case .symbol:
                return password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
            }
        }
    }
}

struct ValidationHelper {

    // MARK: - Email Validation

    /// Massimo consentito da RFC 5321 per l'indirizzo intero.
    private static let maxEmailLength = 254

    private static let invalidDomains = ["test.com", "example.com", "test.test", "test.test.com"]

    static func isValidEmail(_ email: String) -> Bool {
        guard !email.isEmpty, email.count <= maxEmailLength else { return false }

        // Niente spazi: un indirizzo con uno spazio è quasi sempre un incollaggio andato male,
        // e la regex sotto lo accetterebbe se lo spazio finisse nel dominio.
        guard email.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }

        // Due punti consecutivi non sono validi né nella parte locale né nel dominio.
        guard !email.contains("..") else { return false }

        let emailRegex = "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        guard emailPredicate.evaluate(with: email) else { return false }

        let parts = email.components(separatedBy: "@")
        guard parts.count == 2 else { return false }
        let domain = parts[1].lowercased()

        // Il dominio deve avere almeno un punto e non può iniziare o finire con uno.
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }

        return !invalidDomains.contains(domain)
    }

    // MARK: - Password Validation

    static func isValidPassword(_ password: String) -> Bool {
        PasswordPolicy.Rule.allCases.allSatisfy { $0.isSatisfied(by: password) }
    }

    /// Le verifiche con il loro stato: è quello che disegna `PasswordRequirementsChecklist`.
    static func passwordChecks(_ password: String) -> [(key: String, satisfied: Bool)] {
        PasswordPolicy.Rule.allCases.map { (key: $0.rawValue, satisfied: $0.isSatisfied(by: password)) }
    }
}
