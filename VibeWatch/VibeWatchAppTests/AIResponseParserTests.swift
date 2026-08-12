import XCTest
@testable import VibeWatchApp

final class AIResponseParserTests: XCTestCase {

    func testPlainTextPassesThroughUntouched() {
        let raw = "Scorsese è il maestro del crimine americano, difficile sbagliare con lui."
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.text, raw)
        XCTAssertTrue(parsed.recommendations.isEmpty)
    }

    func testFencedVibeJsonBlockIsExtracted() {
        let raw = """
        Scorsese è una garanzia. Di suo ti consiglio questi tre must-watch:
        ```vibe-json
        [{"title":"Goodfellas","year":1990,"type":"movie","reason":"Il gangster movie definitivo.","confidence":92},
         {"title":"Taxi Driver","year":1976,"type":"movie","reason":"Un discesa ossessiva che ami nei tuoi thriller.","confidence":88}]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.text, "Scorsese è una garanzia. Di suo ti consiglio questi tre must-watch:")
        XCTAssertEqual(parsed.recommendations.count, 2)
        XCTAssertEqual(parsed.recommendations[0].title, "Goodfellas")
        XCTAssertEqual(parsed.recommendations[0].year, 1990)
        XCTAssertEqual(parsed.recommendations[0].mediaType, .movie)
        XCTAssertEqual(parsed.recommendations[0].confidence, 92)
    }

    func testPlainJsonFenceAlsoAccepted() {
        let raw = """
        Ecco qualcosa di leggero:
        ```json
        [{"title":"The Office","year":2005,"type":"tv","reason":"Comfort assoluto.","confidence":90}]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.recommendations.count, 1)
        XCTAssertEqual(parsed.recommendations[0].mediaType, .tv)
    }

    func testBareArrayFallbackWithoutFences() {
        let raw = """
        Tre piste nordiche per te:
        [{"title":"Trapped","year":2015,"type":"tv","reason":"Neve e comunità isolata.","confidence":85}]
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.text, "Tre piste nordiche per te:")
        XCTAssertEqual(parsed.recommendations.count, 1)
        XCTAssertEqual(parsed.recommendations[0].title, "Trapped")
    }

    func testMalformedJsonDegradesToPlainText() {
        let raw = """
        Ecco i miei consigli:
        ```vibe-json
        [{"title":"Goodfellas","year":1990,"type":"movie","reason":]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertTrue(parsed.recommendations.isEmpty)
        XCTAssertEqual(parsed.text, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testYearAsStringAndMissingConfidence() {
        let raw = """
        ```vibe-json
        [{"title":"Heat","year":"1995","type":"movie","reason":"Duello Pacino-De Niro."}]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.recommendations.count, 1)
        XCTAssertEqual(parsed.recommendations[0].year, 1995)
        XCTAssertEqual(parsed.recommendations[0].confidence, AIResponseParser.defaultConfidence)
    }

    func testConfidenceIsClamped() {
        let raw = """
        ```vibe-json
        [{"title":"A","type":"movie","reason":"r","confidence":100},
         {"title":"B","type":"movie","reason":"r","confidence":10}]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.recommendations[0].confidence, 97)
        XCTAssertEqual(parsed.recommendations[1].confidence, 55)
    }

    func testUnknownTypeItemsAreDropped() {
        let raw = """
        ```vibe-json
        [{"title":"Valid","type":"tv","reason":"ok","confidence":80},
         {"title":"Podcast?","type":"podcast","reason":"no","confidence":80}]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.recommendations.count, 1)
        XCTAssertEqual(parsed.recommendations[0].title, "Valid")
    }

    func testLastOfMultipleBlocksWins() {
        let raw = """
        Prima bozza:
        ```vibe-json
        [{"title":"Old","type":"movie","reason":"r","confidence":60}]
        ```
        Anzi, meglio questi:
        ```vibe-json
        [{"title":"New","type":"movie","reason":"r","confidence":90}]
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.recommendations.count, 1)
        XCTAssertEqual(parsed.recommendations[0].title, "New")
    }

    func testNonRecommendationArrayStaysInText() {
        let raw = "I voti IMDb sono [8, 9, 7] più o meno."
        let parsed = AIResponseParser.parse(raw)
        XCTAssertTrue(parsed.recommendations.isEmpty)
        XCTAssertEqual(parsed.text, raw)
    }

    func testEmptyRecommendationsKeepTextWhenBlockHasNoItems() {
        let raw = """
        Nessun titolo stavolta.
        ```vibe-json
        []
        ```
        """
        let parsed = AIResponseParser.parse(raw)
        XCTAssertTrue(parsed.recommendations.isEmpty)
    }
}
