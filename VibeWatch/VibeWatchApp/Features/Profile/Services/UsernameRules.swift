import Foundation

/// SPEC v3 §3.6/§3.7 — le regole sullo username, dal lato del client.
///
/// **Perché esistono anche qui, se il server le ha già.** Non per fidarsi del client: il server
/// rifiuta comunque (`set_username` torna `invalid_format`, e il CHECK su `profiles` è l'ultima
/// parola). Servono a rispondere *mentre si digita*, senza un giro di rete per ogni carattere —
/// e a non chiedere al server se `Anna Rossi` è libero quando è già chiaro che non è nemmeno uno
/// username valido.
///
/// Il rischio di una regola duplicata è che le due copie divergano. Qui è contenuto: la forma è
/// un'espressione regolare identica a quella del CHECK, scritta una volta sola, e il verdetto che
/// conta resta quello del server. Ciò che il client **non** duplica è l'elenco dei riservati —
/// non può leggerlo, e indovinarlo sarebbe la copia che diverge davvero.
enum UsernameRules {

    /// La stessa di `profiles_username_format` e di `set_username`.
    static let pattern = "^[a-z0-9_]{3,20}$"
    static let minLength = 3
    static let maxLength = 20

    /// Perché uno username non va bene. Il caso `reserved` non è qui: lo sa solo il server.
    enum Problem: Equatable {
        case empty
        case tooShort
        case tooLong
        case invalidCharacters

        var messageKey: String {
            switch self {
            case .empty: return "username.error.empty"
            case .tooShort: return "username.error.tooShort"
            case .tooLong: return "username.error.tooLong"
            case .invalidCharacters: return "username.error.invalidCharacters"
            }
        }
    }

    /// Il primo problema, o `nil` se la forma va bene.
    ///
    /// L'ordine conta: a chi scrive `Anna Rossi` si dice "solo minuscole, cifre e _", non
    /// "troppo corto" — il secondo sarebbe vero solo dopo aver capito il primo.
    static func problem(with username: String) -> Problem? {
        if username.isEmpty { return .empty }
        if username.range(of: pattern, options: .regularExpression) != nil { return nil }
        // Un carattere non ammesso è più informativo della lunghezza: la lunghezza si vede.
        if username.range(of: "^[a-z0-9_]*$", options: .regularExpression) == nil {
            return .invalidCharacters
        }
        return username.count < minLength ? .tooShort : .tooLong
    }

    static func isWellFormed(_ username: String) -> Bool { problem(with: username) == nil }

    /// Cosa mostrare mentre si digita, senza correggere di nascosto ciò che l'utente ha scritto.
    ///
    /// Si abbassano le maiuscole e si tolgono gli spazi ai bordi perché sono errori di battitura,
    /// non intenzioni; **non** si sostituiscono gli altri caratteri, perché farlo trasformerebbe
    /// `mario.rossi` in `mario_rossi` senza dirlo e l'utente si ritroverebbe un nome che non ha
    /// scelto. Quello lo fa `username_seed`, che serve a *proporre*, non a correggere.
    ///
    /// Vale anche per la lunghezza: niente taglio a `maxLength`. Il taglio faceva dire
    /// "disponibile" al prefisso di 20 caratteri di un nome più lungo — un nome mai digitato —
    /// mentre il suggerimento a fianco diceva "da 3 a 20". Il 21° carattere resta nel campo e
    /// diventa un `.tooLong` visibile, come ogni altro errore di forma.
    static func normalizeTyping(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// L'esito di `set_username`. Gli errori "normali" sono risposte, non eccezioni: uno username
/// occupato è la cosa più probabile che succeda in questa schermata.
enum SetUsernameOutcome: Equatable {
    case saved(username: String, changed: Bool)
    case taken
    case reserved
    case invalidFormat

    /// Dalla `jsonb` che torna l'RPC.
    init(json: [String: Any]) {
        if json["ok"] as? Bool == true {
            self = .saved(
                username: json["username"] as? String ?? "",
                changed: json["changed"] as? Bool ?? false)
            return
        }
        switch json["reason"] as? String {
        case "taken": self = .taken
        case "reserved": self = .reserved
        default: self = .invalidFormat
        }
    }

    var messageKey: String? {
        switch self {
        case .saved: return nil
        case .taken: return "username.error.taken"
        case .reserved: return "username.error.reserved"
        case .invalidFormat: return "username.error.invalidCharacters"
        }
    }
}
