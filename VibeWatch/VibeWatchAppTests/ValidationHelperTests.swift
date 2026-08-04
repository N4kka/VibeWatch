import XCTest
@testable import VibeWatchApp

/// Le regole di email e password sono l'unico filtro prima del server.
///
/// Supabase richiede minuscola, maiuscola, cifra **e simbolo**: finché il client non chiedeva il
/// simbolo, chi si registrava con `Password1` passava la validazione locale e veniva respinto dal
/// server con un errore che non spiegava quale regola mancasse.
final class ValidationHelperTests: XCTestCase {

    // MARK: - Password

    func testPasswordValidaSoddisfaTutteLeRegole() {
        let checks = ValidationHelper.passwordChecks("Password1!")
        XCTAssertTrue(checks.allSatisfy(\.satisfied), "tutte e cinque le regole devono passare")
        XCTAssertTrue(ValidationHelper.isValidPassword("Password1!"))
    }

    func testPasswordSenzaSimboloNonEValida() {
        let checks = ValidationHelper.passwordChecks("Password1")
        let simbolo = checks.first { $0.key == "auth.pwRule.symbol" }

        XCTAssertEqual(simbolo?.satisfied, false)
        XCTAssertFalse(ValidationHelper.isValidPassword("Password1"))
        // Le altre quattro passano: la checklist deve poterlo mostrare regola per regola.
        XCTAssertEqual(checks.filter(\.satisfied).count, 4)
    }

    func testPasswordCortaNonEValida() {
        let checks = ValidationHelper.passwordChecks("Ab1!")
        let lunghezza = checks.first { $0.key == "auth.pwRule.length" }

        XCTAssertEqual(lunghezza?.satisfied, false)
        XCTAssertFalse(ValidationHelper.isValidPassword("Ab1!"))
    }

    func testLeRegoleSonoCinqueENellOrdineDellaChecklist() {
        let checks = ValidationHelper.passwordChecks("")
        XCTAssertEqual(checks.map(\.key), [
            "auth.pwRule.length",
            "auth.pwRule.uppercase",
            "auth.pwRule.lowercase",
            "auth.pwRule.number",
            "auth.pwRule.symbol"
        ])
        XCTAssertTrue(checks.allSatisfy { !$0.satisfied })
    }

    func testLaLunghezzaMinimaSegueLaPolitica() {
        XCTAssertEqual(PasswordPolicy.minLength, 8)
    }

    // MARK: - Email

    func testEmailValida() {
        XCTAssertTrue(ValidationHelper.isValidEmail("a@b.it"))
        XCTAssertTrue(ValidationHelper.isValidEmail("nome.cognome+tag@sotto.dominio.co.uk"))
    }

    func testEmailConDoppioPuntoNonEValida() {
        XCTAssertFalse(ValidationHelper.isValidEmail("a..b@c.it"))
        XCTAssertFalse(ValidationHelper.isValidEmail("a@c..it"))
    }

    func testEmailSenzaPuntoNelDominioNonEValida() {
        XCTAssertFalse(ValidationHelper.isValidEmail("a@b"))
    }

    func testEmailConSpaziNonEValida() {
        XCTAssertFalse(ValidationHelper.isValidEmail("a b@c.it"))
        XCTAssertFalse(ValidationHelper.isValidEmail(" a@c.it"))
        XCTAssertFalse(ValidationHelper.isValidEmail("a@c.it "))
    }

    func testEmailTroppoLungaNonEValida() {
        let locale = String(repeating: "a", count: 250)
        XCTAssertFalse(ValidationHelper.isValidEmail("\(locale)@dominio.it"))
    }

    func testDominiDiProvaRestanoBloccati() {
        XCTAssertFalse(ValidationHelper.isValidEmail("mario@test.com"))
        XCTAssertFalse(ValidationHelper.isValidEmail("mario@example.com"))
    }

    func testEmailVuotaNonEValida() {
        XCTAssertFalse(ValidationHelper.isValidEmail(""))
    }
}
