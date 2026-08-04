import XCTest
@testable import VibeWatchApp

/// La mappa dal dito al voto è l'unica parte del trascinamento che si può sbagliare in silenzio:
/// un fuori-scala scriverebbe un valore che il CHECK del server rifiuta.
@MainActor
final class StarRatingDragTests: XCTestCase {

    private let width: CGFloat = 200   // 5 stelle → 20pt per mezza stella

    func testIlBordoSinistroValeMezzaStella() {
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: 0, totalWidth: width), 1)
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: 1, totalWidth: width), 1)
    }

    func testMetaRigaValeTreStelle() {
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: width / 2, totalWidth: width), 5)
    }

    func testIlBordoDestroValeCinqueStelle() {
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: width, totalWidth: width), 10)
    }

    func testOltreIlBordoDestroRestaDieci() {
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: width * 3, totalWidth: width), 10)
    }

    func testSottoZeroRestaUno() {
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: -50, totalWidth: width), 1)
    }

    func testLarghezzaNullaNonDivide() {
        XCTAssertEqual(StarRatingSection.ratingForDrag(x: 30, totalWidth: 0), 1)
    }

    func testOgniDecimoAvanzaDiMezzaStella() {
        for step in 1...10 {
            let x = width / 10 * CGFloat(step)
            XCTAssertEqual(StarRatingSection.ratingForDrag(x: x, totalWidth: width), step)
        }
    }

    // MARK: - Etichetta della capsula

    func testLaCapsulaMostraLeMezzeStelleConUnDecimale() {
        XCTAssertEqual(StarRatingSection.displayValue(for: 7), "3.5")
        XCTAssertEqual(StarRatingSection.displayValue(for: 1), "0.5")
    }

    func testLaCapsulaNonMostraLoZeroInutile() {
        XCTAssertEqual(StarRatingSection.displayValue(for: 10), "5")
        XCTAssertEqual(StarRatingSection.displayValue(for: 4), "2")
    }
}
