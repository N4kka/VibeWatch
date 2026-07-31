import XCTest
@testable import VibeWatchApp

/// SPEC v3 §3.7/§9.3 — ricerca utenti e profilo pubblico, dal lato del client.
///
/// Il server decide tutto (superficie, blocchi, contatori): qui si verifica che il client non
/// inventi niente — e in particolare che un errore di rete non si travesta da "nessun risultato"
/// o da "questo profilo non esiste", che è la famiglia di bugie di questa sessione.
@MainActor
final class SocialProfileTests: XCTestCase {

    // MARK: - Parse delle risposte

    func testUnProfiloSiLeggeDallaRisposta() {
        let detail = PublicProfileDetail(json: [
            "found": true, "id": "u1", "username": "anna_r", "display_name": "Anna",
            "followers": 3, "following": 7, "is_following": true, "follows_me": false,
        ])
        XCTAssertEqual(detail?.profile.username, "anna_r")
        XCTAssertEqual(detail?.followers, 3)
        XCTAssertEqual(detail?.following, 7)
        XCTAssertEqual(detail?.isFollowing, true)
        XCTAssertEqual(detail?.followsMe, false)
    }

    /// `found: false` copre anche bloccato/privato/cancellato: il server non li distingue apposta.
    func testFoundFalseENil() {
        XCTAssertNil(PublicProfileDetail(json: ["found": false]))
        XCTAssertNil(PublicProfileDetail(json: [:]),
                     "una risposta senza `found` non diventa un profilo")
    }

    func testUnaRigaDiRicercaSenzaUsernameSiScarta() {
        XCTAssertNil(PublicProfile(json: ["id": "u1"]))
        XCTAssertNil(PublicProfile(json: ["username": "anna"]))
    }

    // MARK: - La ricerca

    func testLaRicercaTrova() async throws {
        let vm = UserSearchViewModel(
            search: { _ in [PublicProfile(id: "u1", username: "anna_r")] },
            debounce: .milliseconds(1))
        vm.query = "anna"
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.phase, .results([PublicProfile(id: "u1", username: "anna_r")]))
    }

    func testZeroRisultatiEDiversoDaErrore() async throws {
        let vuota = UserSearchViewModel(search: { _ in [] }, debounce: .milliseconds(1))
        vuota.query = "nessuno"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vuota.phase, .empty)

        struct Rotto: Error {}
        let rotta = UserSearchViewModel(search: { _ in throw Rotto() }, debounce: .milliseconds(1))
        rotta.query = "anna"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rotta.phase, .failed,
                       "un errore di rete non si traveste da 'nessuno trovato'")
    }

    func testQueryVuotaNonCercaNiente() async throws {
        var chiamate = 0
        let vm = UserSearchViewModel(
            search: { _ in chiamate += 1; return [] }, debounce: .milliseconds(1))
        vm.query = "   "
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(chiamate, 0, "spazi non sono una query")
    }

    // MARK: - Il profilo

    private func dettaglio(isFollowing: Bool = false, followers: Int = 5) -> PublicProfileDetail {
        PublicProfileDetail(
            profile: PublicProfile(id: "u2", username: "zed"),
            followers: followers, following: 1, isFollowing: isFollowing, followsMe: true)
    }

    func testIlProfiloSiCarica() async {
        let vm = PublicProfileViewModel(
            username: "zed", load: { _ in self.dettaglio() },
            follow: { _ in }, unfollow: { _ in })
        await vm.loadProfile()
        XCTAssertEqual(vm.phase, .loaded(dettaglio()))
    }

    func testInesistenteEDiversoDaErrore() async {
        let sparito = PublicProfileViewModel(
            username: "nessuno", load: { _ in nil }, follow: { _ in }, unfollow: { _ in })
        await sparito.loadProfile()
        XCTAssertEqual(sparito.phase, .notFound)

        struct Rotto: Error {}
        let rotto = PublicProfileViewModel(
            username: "zed", load: { _ in throw Rotto() }, follow: { _ in }, unfollow: { _ in })
        await rotto.loadProfile()
        XCTAssertEqual(rotto.phase, .failed,
                       "un errore di rete non e' 'questo profilo non esiste'")
    }

    /// Dopo la scrittura si **rilegge**: i contatori sono del server (§1.1), e il follow deve
    /// arrivare al backend con l'id giusto.
    func testSeguireScriveERilegge() async {
        var seguiti: [String] = []
        var letture = 0
        let vm = PublicProfileViewModel(
            username: "zed",
            load: { _ in
                letture += 1
                return self.dettaglio(isFollowing: !seguiti.isEmpty,
                                      followers: 5 + seguiti.count)
            },
            follow: { seguiti.append($0) },
            unfollow: { _ in XCTFail("non doveva mai smettere di seguire") })
        await vm.loadProfile()

        await vm.toggleFollow()

        XCTAssertEqual(seguiti, ["u2"], "il follow parte con l'id del profilo mostrato")
        XCTAssertEqual(letture, 2, "dopo la scrittura si rilegge: i numeri li fa il server")
        XCTAssertEqual(vm.phase, .loaded(dettaglio(isFollowing: true, followers: 6)))
    }

    func testSmettereDiSeguirePassaDallUnfollow() async {
        var unfollowed: [String] = []
        let vm = PublicProfileViewModel(
            username: "zed",
            load: { _ in self.dettaglio(isFollowing: unfollowed.isEmpty) },
            follow: { _ in XCTFail("gia' seguito: doveva fare unfollow") },
            unfollow: { unfollowed.append($0) })
        await vm.loadProfile()

        await vm.toggleFollow()

        XCTAssertEqual(unfollowed, ["u2"])
        XCTAssertEqual(vm.phase, .loaded(dettaglio(isFollowing: false)))
    }

    /// Trovato sul dispositivo il 2026-07-31: il proprio profilo (raggiungibile dalla ricerca,
    /// e va bene cosi') mostrava il pulsante "Segui". Il tap partiva, il CHECK del server lo
    /// respingeva come rifiuto muto, la schermata tornava com'era — l'invito a ripremere.
    func testIlProprioProfiloNonSiSegue() async {
        let vm = PublicProfileViewModel(
            username: "zed",
            load: { _ in self.dettaglio() },
            follow: { _ in XCTFail("un self-follow non deve nemmeno partire") },
            unfollow: { _ in XCTFail("nemmeno l'unfollow") },
            currentUserId: { "u2" })   // il profilo mostrato e' il chiamante
        await vm.loadProfile()

        XCTAssertTrue(vm.isOwnProfile, "e' cosi' che la View sa di nascondere il pulsante")
        await vm.toggleFollow()
        XCTAssertEqual(vm.phase, .loaded(dettaglio()), "niente e' cambiato, niente e' partito")
    }

    func testIlProfiloDiUnAltroNonEIlProprio() async {
        let vm = PublicProfileViewModel(
            username: "zed", load: { _ in self.dettaglio() },
            follow: { _ in }, unfollow: { _ in },
            currentUserId: { "u1" })
        await vm.loadProfile()
        XCTAssertFalse(vm.isOwnProfile)
    }

    /// Se la scrittura fallisce lo stato torna quello del server, non quello sperato.
    func testUnFollowFallitoNonMenteSulloStato() async {
        struct Rotto: Error {}
        let vm = PublicProfileViewModel(
            username: "zed",
            load: { _ in self.dettaglio(isFollowing: false) },
            follow: { _ in throw Rotto() },
            unfollow: { _ in })
        await vm.loadProfile()

        await vm.toggleFollow()

        XCTAssertEqual(vm.phase, .loaded(dettaglio(isFollowing: false)),
                       "il pulsante non resta su 'seguito' se il server non ha mai saputo niente")
        XCTAssertFalse(vm.isTogglingFollow)
    }
}
