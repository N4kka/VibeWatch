import Foundation

/// SPEC v3 §3.7 — "agli utenti esistenti va assegnato uno username […] con richiesta di conferma
/// al primo accesso".
///
/// **Due schermate in una, e la differenza non è cosmetica.** Il backfill ha assegnato uno
/// username a 295 profili su 314 e ne ha lasciati **19** senza, perché il loro nome non era
/// riducibile a `[a-z0-9_]` (nomi cinesi, cirillici, troppo corti) e derivarlo dall'email sarebbe
/// stata una fuga. Per i 295 questa è una conferma: c'è già un nome, basta accettarlo. Per i 19 è
/// l'unico modo di esistere socialmente — senza username non compaiono in `public_profiles`,
/// quindi non sono cercabili e non hanno un profilo pubblico.
@MainActor
final class UsernameSetupViewModel: ObservableObject {

    enum Mode: Equatable {
        /// Ha già uno username, glielo abbiamo dato noi: conferma o cambia.
        case confirm(assigned: String)
        /// Non ne ha: deve sceglierne uno per comparire da qualche parte.
        case choose
    }

    /// Cosa dire accanto al campo mentre si digita.
    enum Status: Equatable {
        case idle
        case checking
        case available
        case unavailable(messageKey: String)
    }

    @Published private(set) var mode: Mode = .choose
    @Published private(set) var status: Status = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    @Published var typed: String = "" {
        didSet {
            let normalized = UsernameRules.normalizeTyping(typed)
            if normalized != typed { typed = normalized; return }   // il didSet rientra una volta
            scheduleCheck()
        }
    }

    /// Si può salvare? Anche `available` non basta da solo: durante il salvataggio no.
    var canSubmit: Bool {
        guard !isSaving else { return false }
        if case .confirm(let assigned) = mode, typed == assigned { return true }
        return status == .available
    }

    private let backend: any UsernameBackend
    private var checkTask: Task<Void, Never>?
    /// Quanto si aspetta prima di chiedere al server. Un giro di rete per carattere sarebbe
    /// venti richieste per uno username di venti lettere.
    private let debounce: Duration

    init(backend: (any UsernameBackend)? = nil, debounce: Duration = .milliseconds(400)) {
        self.backend = backend ?? SupabaseUsernameBackend()
        self.debounce = debounce
    }

    /// Legge lo stato e decide quale delle due schermate mostrare.
    func load() async {
        guard let state = try? await backend.currentState() else { return }
        if let username = state.username, !username.isEmpty {
            mode = .confirm(assigned: username)
            typed = username
            // Non si controlla la disponibilità del proprio nome: è occupato **da sé stessi**, e
            // il server risponderebbe "no". Sarebbe un "non disponibile" rosso sotto il nome che
            // la schermata sta chiedendo di confermare.
            status = .idle
        } else {
            mode = .choose
            typed = ""
            status = .idle
        }
    }

    /// Chiede al server se serve mostrare la schermata. Nessuna schermata è la risposta giusta
    /// per chi ha già confermato.
    static func isNeeded(backend: (any UsernameBackend)? = nil) async -> Bool {
        let backend = backend ?? SupabaseUsernameBackend()
        guard let state = try? await backend.currentState() else {
            // Non si sa: non si disturba l'utente. Si riproverà al prossimo avvio.
            return false
        }
        return state.username == nil || !state.confirmed
    }

    func submit() async -> Bool {
        guard canSubmit else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            let outcome = try await backend.save(typed)
            switch outcome {
            case .saved:
                return true
            case .taken, .reserved, .invalidFormat:
                // Il server ha l'ultima parola e può dire cose che il client non sa: "riservato"
                // è una di quelle. Si mostra accanto al campo, non come errore di sistema.
                status = .unavailable(messageKey: outcome.messageKey ?? "username.error.taken")
                return false
            }
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    // MARK: - Verifica mentre si digita

    private func scheduleCheck() {
        checkTask?.cancel()
        saveError = nil

        // Confermare il proprio nome non è una verifica: è già suo.
        if case .confirm(let assigned) = mode, typed == assigned {
            status = .idle
            return
        }

        if let problem = UsernameRules.problem(with: typed) {
            // La forma si sa da qui: niente giro di rete per dire "ci sono spazi".
            status = typed.isEmpty ? .idle : .unavailable(messageKey: problem.messageKey)
            return
        }

        status = .checking
        let candidate = typed
        checkTask = Task { [weak self, debounce, backend] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let free = (try? await backend.isAvailable(candidate)) ?? false
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.typed == candidate else { return }   // ha continuato a scrivere
                self.status = free ? .available : .unavailable(messageKey: "username.error.taken")
            }
        }
    }
}

// MARK: - La dipendenza, isolata

@MainActor
protocol UsernameBackend {
    func currentState() async throws -> (username: String?, confirmed: Bool)
    func isAvailable(_ username: String) async throws -> Bool
    func save(_ username: String) async throws -> SetUsernameOutcome
}

@MainActor
struct SupabaseUsernameBackend: UsernameBackend {
    func currentState() async throws -> (username: String?, confirmed: Bool) {
        try await SupabaseService.shared.usernameState() ?? (nil, false)
    }
    func isAvailable(_ username: String) async throws -> Bool {
        try await SupabaseService.shared.usernameAvailable(username)
    }
    func save(_ username: String) async throws -> SetUsernameOutcome {
        try await SupabaseService.shared.setUsername(username)
    }
}
