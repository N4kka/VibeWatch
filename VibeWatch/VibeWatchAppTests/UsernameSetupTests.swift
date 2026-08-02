import XCTest
@testable import VibeWatchApp

/// SPEC v3 §3.7 — le regole sullo username dal lato client e le due schermate in una.
@MainActor
final class UsernameSetupTests: XCTestCase {

    // MARK: - Le regole, che sono pure

    func testLaFormaValidaPassa() {
        XCTAssertNil(UsernameRules.problem(with: "anna_rossi"))
        XCTAssertNil(UsernameRules.problem(with: "abc"))
        XCTAssertNil(UsernameRules.problem(with: "a1_"))
    }

    /// L'ordine dei messaggi conta: a chi scrive "Anna Rossi" si dice "solo minuscole, cifre e _",
    /// non "troppo corto" — il secondo sarebbe vero solo dopo aver capito il primo.
    func testIlProblemaPiuInformativoVinceSullaLunghezza() {
        XCTAssertEqual(UsernameRules.problem(with: "Anna Rossi"), .invalidCharacters)
        XCTAssertEqual(UsernameRules.problem(with: "A"), .invalidCharacters)
        XCTAssertEqual(UsernameRules.problem(with: "ab"), .tooShort)
        XCTAssertEqual(UsernameRules.problem(with: String(repeating: "a", count: 21)), .tooLong)
        XCTAssertEqual(UsernameRules.problem(with: ""), .empty)
    }

    /// La stessa espressione del CHECK su `profiles` e di `set_username`. Se questa diverge, il
    /// client dice "va bene" e il server rifiuta.
    func testLaFormaEQuellaDelServer() {
        XCTAssertEqual(UsernameRules.pattern, "^[a-z0-9_]{3,20}$")
        XCTAssertEqual(UsernameRules.minLength, 3)
        XCTAssertEqual(UsernameRules.maxLength, 20)
    }

    /// Si correggono gli errori di battitura, non le intenzioni: `mario.rossi` resta com'e' e
    /// diventa un errore visibile, invece di trasformarsi in `mario_rossi` di nascosto.
    func testLaNormalizzazioneNonRiscriveCioCheLUtenteHaScelto() {
        XCTAssertEqual(UsernameRules.normalizeTyping("  Anna  "), "anna")
        XCTAssertEqual(UsernameRules.normalizeTyping("MARIO"), "mario")
        XCTAssertEqual(UsernameRules.normalizeTyping("mario.rossi"), "mario.rossi",
                       "il punto resta e diventa un errore visibile, non una sostituzione muta")
        // Trovato sul dispositivo: il taglio a 20 faceva dire "disponibile" al prefisso di un
        // nome piu' lungo — un nome mai digitato — col suggerimento a fianco che diceva "3-20".
        let lungo = String(repeating: "a", count: 30)
        XCTAssertEqual(UsernameRules.normalizeTyping(lungo), lungo,
                       "la lunghezza non si corregge di nascosto: diventa un .tooLong visibile")
        XCTAssertEqual(UsernameRules.problem(with: lungo), .tooLong)
    }

    // MARK: - L'esito dell'RPC

    func testGliEsitiSiLeggonoDallaRisposta() {
        XCTAssertEqual(SetUsernameOutcome(json: ["ok": true, "username": "anna", "changed": true]),
                       .saved(username: "anna", changed: true))
        XCTAssertEqual(SetUsernameOutcome(json: ["ok": false, "reason": "taken"]), .taken)
        XCTAssertEqual(SetUsernameOutcome(json: ["ok": false, "reason": "reserved"]), .reserved)
        // Una risposta che non si capisce non diventa un successo.
        XCTAssertEqual(SetUsernameOutcome(json: [:]), .invalidFormat)
    }

    /// PostgREST serializza una funzione `returns boolean` come `true`/`false` nudo: un frammento
    /// JSON di primo livello. Il parse senza `.fragmentsAllowed` falliva su **ogni** risposta, e il
    /// `?? false` la traduceva in "già preso" — anche per i nomi liberi. Trovato sul dispositivo:
    /// i doppi di questi test non passano dal parse, quindi erano verdi col difetto dentro.
    func testLaRispostaBooleanaNudaDiPostgRESTSiLegge() throws {
        XCTAssertTrue(try SupabaseService.parseBooleanRPCResponse(Data("true".utf8)))
        XCTAssertFalse(try SupabaseService.parseBooleanRPCResponse(Data("false".utf8)))
    }

    /// Una risposta che non si capisce è un errore, non un "no".
    func testUnaRispostaIllegibileEUnErroreNonUnNo() {
        XCTAssertThrowsError(try SupabaseService.parseBooleanRPCResponse(Data("<html>".utf8)))
        XCTAssertThrowsError(try SupabaseService.parseBooleanRPCResponse(Data()))
    }

    // MARK: - Le due schermate

    /// I 295 del backfill: c'e' gia' un nome, basta accettarlo.
    func testChiHaGiaUnoUsernameVedeLaConferma() async {
        let vm = UsernameSetupViewModel(backend: Fake(username: "anna_rossi"))
        await vm.load()

        XCTAssertEqual(vm.mode, .confirm(assigned: "anna_rossi"))
        XCTAssertEqual(vm.typed, "anna_rossi")
        XCTAssertTrue(vm.canSubmit, "confermare il proprio nome si deve poter fare subito")
        XCTAssertEqual(vm.status, .idle,
                       "e non si chiede al server se e' libero: e' occupato da chi lo porta")
    }

    /// I 19 senza nome derivabile: per loro non e' una conferma, e' l'unico modo di esistere.
    func testChiNonHaUnoUsernameDeveSceglierlo() async {
        let vm = UsernameSetupViewModel(backend: Fake(username: nil))
        await vm.load()

        XCTAssertEqual(vm.mode, .choose)
        XCTAssertEqual(vm.typed, "")
        XCTAssertFalse(vm.canSubmit, "senza aver scritto niente non si va avanti")
    }

    /// La schermata compare solo a chi serve, e la domanda la fa il server.
    func testQuandoServeLaSchermata() async {
        var needed = await UsernameSetupViewModel.isNeeded(
            backend: Fake(username: "anna", confirmed: false))
        XCTAssertTrue(needed, "assegnato dal backfill e mai confermato")

        needed = await UsernameSetupViewModel.isNeeded(backend: Fake(username: nil))
        XCTAssertTrue(needed, "nessuno username")

        needed = await UsernameSetupViewModel.isNeeded(
            backend: Fake(username: "anna", confirmed: true))
        XCTAssertFalse(needed, "gia' confermato: non si disturba piu'")
    }

    /// Se non si riesce a chiedere, non si disturba l'utente: si riprova al prossimo avvio.
    func testSeLaLetturaFallisceLaSchermataNonCompare() async {
        let needed = await UsernameSetupViewModel.isNeeded(backend: Fake(failing: true))
        XCTAssertFalse(needed)
    }

    /// Un errore di forma si vede senza chiedere niente al server: venti richieste per venti
    /// lettere sarebbero venti giri di rete per dire "ci sono spazi".
    func testUnErroreDiFormaNonCostaUnGiroDiRete() async throws {
        let fake = Fake(username: nil)
        let vm = UsernameSetupViewModel(backend: fake, debounce: .milliseconds(1))
        await vm.load()

        vm.typed = "ab"
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.status, .unavailable(messageKey: "username.error.tooShort"))
        XCTAssertEqual(fake.availabilityChecks, 0, "il server non e' stato interpellato")
    }

    /// Il 21° carattere non sparisce: resta nel campo e il nome diventa un errore visibile,
    /// coerente col suggerimento "da 3 a 20 caratteri".
    func testOltreVentiCaratteriSiDiceTroppoLungoNonDisponibile() async throws {
        let fake = Fake(username: nil)
        let vm = UsernameSetupViewModel(backend: fake, debounce: .milliseconds(1))
        await vm.load()

        vm.typed = String(repeating: "a", count: 21)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.typed.count, 21, "il campo tiene cio' che l'utente ha scritto")
        XCTAssertEqual(vm.status, .unavailable(messageKey: "username.error.tooLong"))
        XCTAssertFalse(vm.canSubmit)
        XCTAssertEqual(fake.availabilityChecks, 0, "la lunghezza si vede da qui, niente rete")
    }

    func testUnNomeLiberoDiventaSelezionabile() async throws {
        let vm = UsernameSetupViewModel(backend: Fake(username: nil), debounce: .milliseconds(1))
        await vm.load()

        vm.typed = "anna_nuova"
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.status, .available)
        XCTAssertTrue(vm.canSubmit)
    }

    func testUnNomeOccupatoSiDiceOccupato() async throws {
        let vm = UsernameSetupViewModel(backend: Fake(username: nil, available: false),
                                        debounce: .milliseconds(1))
        await vm.load()

        vm.typed = "anna_rossi"
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.status, .unavailable(messageKey: "username.error.taken"))
        XCTAssertFalse(vm.canSubmit)
    }

    /// Il difetto trovato sul dispositivo, dal lato del ViewModel: un errore nella verifica
    /// diventava "già preso". Un guasto si dice per quello che è, non spacciandolo per una
    /// risposta del server.
    func testUnErroreDiVerificaNonDiventaGiaPreso() async throws {
        let vm = UsernameSetupViewModel(backend: Fake(username: nil, availabilityFails: true),
                                        debounce: .milliseconds(1))
        await vm.load()

        vm.typed = "anna_rossi"
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.status, .unavailable(messageKey: "username.error.checkFailed"))
        XCTAssertFalse(vm.canSubmit, "senza una risposta vera non si va avanti")
    }

    /// "Occupato" e "riservato" sono risposte, non errori di sistema: si mostrano accanto al campo.
    func testUnNomeRifiutatoDalServerSiMostraAccantoAlCampo() async throws {
        let vm = UsernameSetupViewModel(backend: Fake(username: nil, outcome: .reserved),
                                        debounce: .milliseconds(1))
        await vm.load()
        vm.typed = "admin"
        try await Task.sleep(for: .milliseconds(80))

        let salvato = await vm.submit()

        XCTAssertFalse(salvato)
        XCTAssertEqual(vm.status, .unavailable(messageKey: "username.error.reserved"))
        XCTAssertNil(vm.saveError, "non e' un errore di sistema: non va nel riquadro rosso")
    }

    // MARK: - Doppio

    @MainActor
    private final class Fake: UsernameBackend {
        private(set) var availabilityChecks = 0
        private let username: String?
        private let confirmed: Bool
        private let outcome: SetUsernameOutcome
        private let failing: Bool
        private let available: Bool
        private let availabilityFails: Bool
        struct Rotto: Error {}

        init(username: String? = nil, confirmed: Bool = false,
             outcome: SetUsernameOutcome = .saved(username: "x", changed: true),
             failing: Bool = false, available: Bool = true, availabilityFails: Bool = false) {
            self.username = username
            self.confirmed = confirmed
            self.outcome = outcome
            self.failing = failing
            self.available = available
            self.availabilityFails = availabilityFails
        }

        func currentState() async throws -> (username: String?, confirmed: Bool) {
            if failing { throw Rotto() }
            return (username, confirmed)
        }
        func isAvailable(_ username: String) async throws -> Bool {
            availabilityChecks += 1
            if availabilityFails { throw Rotto() }
            return available
        }
        func save(_ username: String) async throws -> SetUsernameOutcome { outcome }
    }
}
