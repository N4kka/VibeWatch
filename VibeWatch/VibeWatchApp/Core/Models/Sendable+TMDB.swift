import Foundation

// TMDB models used across actors/services; mark as Sendable for Swift 6 checks.
extension Movie {}
extension TVShow: @unchecked Sendable {}
extension Video: @unchecked Sendable {}
extension Credits: @unchecked Sendable {}
extension Crew: @unchecked Sendable {}
extension Cast: @unchecked Sendable {}
extension WatchProvider: @unchecked Sendable {}
extension CountryProviders: @unchecked Sendable {}
extension TMDBVideosResponse: @unchecked Sendable {}
extension TMDBMultiResponse: @unchecked Sendable {}
extension SearchResult: @unchecked Sendable {}
extension PersonDetails: @unchecked Sendable {}
extension PersonCombinedCredits: @unchecked Sendable {}
