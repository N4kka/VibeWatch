import XCTest
@testable import VibeWatchApp

final class RedesignPresentationTests: XCTestCase {

    func testPlatformSelectionCodecRoundTripsReferencePlatforms() throws {
        let platforms: Set<StreamingPlatform> = [.netflix, .disney, .prime, .sky, .now, .apple]

        let encoded = try PlatformSelectionCodec.encode(platforms)
        let decoded = PlatformSelectionCodec.decode(encoded)

        XCTAssertEqual(decoded, platforms)
    }

    func testAvailableProviderPresentationBuildsOrderedReferenceTiers() throws {
        let providers = CountryProviders(
            flatrate: [provider(1, "Netflix"), provider(2, "Now")],
            rent: [provider(3, "Apple TV"), provider(4, "Prime Video")],
            buy: [provider(3, "Apple TV"), provider(5, "YouTube")],
            link: nil
        )

        let presentation = MediaDetailProviderPresentation.make(from: .available(providers))

        XCTAssertTrue(presentation.canExpand)
        XCTAssertEqual(presentation.primaryProviderName, "Netflix")
        XCTAssertEqual(presentation.tiers.map(\.titleKey), [
            "platforms.streaming", "platforms.rent", "platforms.buy"
        ])
        XCTAssertEqual(presentation.tiers[0].providers.map(\.providerName), ["Netflix", "Now"])
        XCTAssertEqual(presentation.tiers[1].providers.map(\.providerName), ["Apple TV", "Prime Video"])
        XCTAssertEqual(presentation.tiers[2].providers.map(\.providerName), ["Apple TV", "YouTube"])
    }

    func testUnavailableProviderPresentationIsNonExpandableNotifyMeAction() {
        let presentation = MediaDetailProviderPresentation.make(from: .unavailable)

        XCTAssertFalse(presentation.canExpand)
        XCTAssertNil(presentation.primaryProviderName)
        XCTAssertEqual(presentation.callToActionKey, "mediaDetail.notifyMe")
        XCTAssertTrue(presentation.tiers.isEmpty)
    }

    func testNotifyMeCTAIsDisabledAndChangesCopyAfterFirstTap() {
        XCTAssertEqual(MediaNotificationCTAState.idle.titleKey, "mediaDetail.notifyMe")
        XCTAssertFalse(MediaNotificationCTAState.idle.isButtonDisabled)

        XCTAssertEqual(MediaNotificationCTAState.enabling.titleKey, "mediaDetail.notifyMeEnabling")
        XCTAssertTrue(MediaNotificationCTAState.enabling.isButtonDisabled)

        XCTAssertEqual(MediaNotificationCTAState.enabled.titleKey, "mediaDetail.notifyMeEnabled")
        XCTAssertTrue(MediaNotificationCTAState.enabled.isButtonDisabled)
    }

    func testNotificationEnrollmentCodecPersistsPerUserAndMedia() throws {
        let movieKey = MediaNotificationEnrollmentCodec.key(
            userId: "user-a",
            mediaId: 42,
            mediaType: .movie
        )
        let showKey = MediaNotificationEnrollmentCodec.key(
            userId: "user-a",
            mediaId: 42,
            mediaType: .tv
        )
        let otherUserKey = MediaNotificationEnrollmentCodec.key(
            userId: "user-b",
            mediaId: 42,
            mediaType: .movie
        )

        let encoded = try MediaNotificationEnrollmentCodec.encode([movieKey])
        let decoded = MediaNotificationEnrollmentCodec.decode(encoded)

        XCTAssertTrue(decoded.contains(movieKey))
        XCTAssertFalse(decoded.contains(showKey))
        XCTAssertFalse(decoded.contains(otherUserKey))
    }

    func testFeedbackCopyDistinguishesSuccessfulMediaActions() {
        XCTAssertEqual(
            MediaDetailFeedback.messageKey(for: .watchlist, isActive: true),
            "mediaDetail.toast.watchlistAdded"
        )
        XCTAssertEqual(
            MediaDetailFeedback.messageKey(for: .watchlist, isActive: false),
            "mediaDetail.toast.watchlistRemoved"
        )
        XCTAssertEqual(
            MediaDetailFeedback.messageKey(for: .seen, isActive: true),
            "mediaDetail.toast.markedSeen"
        )
        XCTAssertEqual(
            MediaDetailFeedback.messageKey(for: .liked, isActive: true),
            "mediaDetail.toast.liked"
        )
    }

    func testWhyForMePresentationUsesDedicatedDistinctAISections() {
        let analysis = WhyForMeAnalysis(
            mood: "Il tono romantico e leggero accompagna il mood che cerchi più spesso.",
            genres: "La commedia romantica riprende il tipo di storie che apprezzi.",
            cast: "Hugh Grant e Julia Roberts danno alla storia una chimica molto naturale."
        )
        let result = WhyForMePresentation.make(
            analysis: analysis,
            affinityPercent: 80
        )

        XCTAssertEqual(result.affinityPercent, 80)
        XCTAssertEqual(result.reasons.count, 3)
        XCTAssertEqual(result.reasons.map(\.titleKey), [
            "mediaDetail.why.reason.mood",
            "mediaDetail.why.reason.genres",
            "mediaDetail.why.reason.cast"
        ])
        XCTAssertEqual(result.reasons.map(\.body), [analysis.mood, analysis.genres, analysis.cast])
        XCTAssertEqual(Set(result.reasons.map(\.body)).count, 3)
    }

    func testWhyForMePromptRequiresAUsefulAnswerForEverySection() {
        let movie = MovieDetails(
            id: 1,
            title: "Notting Hill",
            overview: "Una star e un libraio si innamorano a Londra.",
            releaseDate: "1999-05-21",
            voteAverage: 7.3,
            voteCount: 8_000,
            runtime: 124,
            genres: [.init(id: 35, name: "Commedia"), .init(id: 10749, name: "Romance")],
            credits: .init(
                cast: [.init(id: 1, name: "Julia Roberts", character: "Anna Scott")],
                crew: nil
            )
        )

        let prompt = AIContextBuilder.shared.buildWhyForMePrompt(
            movie: movie,
            userProfile: .empty
        )

        XCTAssertTrue(prompt.contains("\"mood\""))
        XCTAssertTrue(prompt.contains("\"genres\""))
        XCTAssertTrue(prompt.contains("\"cast\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("insufficient"))
    }

    func testFAQIdentityIsStableAcrossReconstruction() {
        let first = HelpFAQItem(questionKey: "profile.faq.question1", answerKey: "profile.faq.answer1")
        let second = HelpFAQItem(questionKey: "profile.faq.question1", answerKey: "profile.faq.answer1")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, "profile.faq.question1")
    }

    func testGamificationProgressPreviewKeepsNearbyLevelsAndNextRankMilestone() {
        XCTAssertEqual(
            GamificationProgressPresentation.previewLevels(currentLevel: 1),
            [1, 2, 3, 6]
        )
        XCTAssertEqual(
            GamificationProgressPresentation.previewLevels(currentLevel: 49),
            [49, 50]
        )
    }

    private func provider(_ id: Int, _ name: String) -> Provider {
        Provider(
            providerId: id,
            providerName: name,
            logoPath: "/\(id).png",
            displayPriority: id,
            price: nil,
            quality: nil,
            presentationType: nil,
            externalLink: nil
        )
    }
}
