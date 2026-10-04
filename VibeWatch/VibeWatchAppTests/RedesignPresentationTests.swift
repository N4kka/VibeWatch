import SwiftUI
import UIKit
import XCTest
@testable import VibeWatchApp

final class RedesignPresentationTests: XCTestCase {

    @MainActor
    func testNotificationAuthorizationAdvancesOnboardingAsSoonAsNativeDecisionResolves() async {
        let viewModel = OnboardingViewModel()
        viewModel.currentStep = .notifications

        let granted = await viewModel.resolveNotificationPermission {
            true
        }

        XCTAssertTrue(granted)
        XCTAssertTrue(viewModel.notificationsGranted)
        XCTAssertEqual(
            viewModel.currentStep.rawValue,
            OnboardingViewModel.OnboardingStep.ready.rawValue
        )
    }

    @MainActor
    func testDiscoverModeSwitcherSelectedTitleUsesTabAccentColor() {
        let control = UISegmentedControl(items: ["Scopri", "Clip"])

        DiscoverModeSwitcherStyle.apply(to: control)

        let selectedColor = control.titleTextAttributes(for: .selected)?[.foregroundColor] as? UIColor
        XCTAssertEqual(selectedColor, UIColor(Color.theme.accentOrange))
    }

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

    /// "Film al cinema a settembre 2026" got "I don't have real-time data": the question has to
    /// resolve to real dates so the app can hand TMDB's releases to the model.
    func testReleaseQuestionsResolveToTheDatesAsked() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        func window(_ query: String) -> AIQueryClassifier.ReleaseWindow? {
            AIQueryClassifier.shared.releaseWindow(in: query, now: now, calendar: calendar)
        }

        XCTAssertEqual(
            window("Fammi un elenco dei film che escono al cinema a settembre 2026"),
            .init(from: "2026-09-01", to: "2026-09-30", theatrical: true))
        // A month already past means next year's.
        XCTAssertEqual(
            window("what comes out in march?"),
            .init(from: "2027-03-01", to: "2027-03-31", theatrical: false))
        XCTAssertEqual(
            window("film in uscita la prossima settimana"),
            .init(from: "2026-09-18", to: "2026-09-24", theatrical: false))
        XCTAssertEqual(
            window("cosa danno al cinema?"),
            .init(from: "2026-09-11", to: "2026-10-11", theatrical: true))
        // About one title, not a list of releases.
        XCTAssertNil(window("quando esce Dune 3?"))
        XCTAssertNil(window("consigliami un horror"))
    }

    /// Il bug che ha originato lo split fra `[skip]` e `[saved]`: watchlist e visti finivano
    /// fusi in un unico "mai consigliare questi", quindi "consigliami qualcosa dalla mia
    /// watchlist" tornava con tre titoli di fuori — l'unica risposta coerente col prompt.
    func testUserTurnKeepsSavedTitlesOutOfTheSkipList() {
        let turn = AIContextBuilder.shared.buildUserTurn(
            query: "qualcosa da 90 minuti dalla watchlist",
            userProfile: nil,
            seenTitles: ["Heat"],
            savedEntries: [
                .init(tmdbId: 242582, mediaType: .movie, title: "Nightcrawler", year: 2014, runtime: 117, listName: nil),
                .init(tmdbId: 1091, mediaType: .movie, title: "The Thing", year: 1982, runtime: 109, listName: "horror"),
                .init(tmdbId: 154385, mediaType: .tv, title: "Beef", year: 2023, runtime: nil, listName: nil)
            ]
        )

        XCTAssertTrue(turn.contains("[skip] Heat"))
        XCTAssertFalse(turn.contains("[skip] Heat, Nightcrawler"))
        // La durata viene dalla riga di lista in locale: e' cio' che permette di rispondere
        // a "massimo 90 minuti" senza chiederlo a TMDB e senza farlo ricordare al modello.
        XCTAssertTrue(turn.contains("[saved] Nightcrawler (2014) · 117min; The Thing (1982) · 109min · horror; Beef (2023)"))
        XCTAssertTrue(turn.hasSuffix("\n\nqualcosa da 90 minuti dalla watchlist"))
    }

    /// Successo il 2026-09-11: "The Hunt" (2013) ha agganciato un cortometraggio omonimo da otto
    /// minuti — primo risultato con anno compatibile, tre voti, nessun poster — e la card che ne
    /// e' uscita sembrava un film vero.
    @MainActor
    func testAmbiguousTitleResolvesToTheFilmPeopleActuallyMean() {
        struct Candidate { let id: Int; let year: String?; let votes: Int }
        let short = Candidate(id: 1, year: "2013", votes: 3)
        let real = Candidate(id: 2, year: "2012", votes: 4200)

        let pick = { (results: [Candidate], year: Int?) in
            AIRecommendationViewModel.pickBestMatch(
                results, year: year, yearOf: { $0.year }, votesOf: { $0.votes })
        }

        // Anno compatibile per entrambi (±1): decide il numero di voti, non l'ordine.
        XCTAssertEqual(pick([short, real], 2013)?.id, real.id)
        // Senza anno resta l'ordine di TMDB, che e' gia' per popolarita'.
        XCTAssertEqual(pick([short, real], nil)?.id, short.id)
        // Nessun compatibile: si ripiega sul primo, non si inventa niente.
        XCTAssertEqual(pick([short], 1980)?.id, short.id)
        XCTAssertNil(pick([], 2013))
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
