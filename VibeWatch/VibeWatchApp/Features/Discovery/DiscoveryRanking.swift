import Foundation

/// Pure, side-effect-free ranking logic extracted from `DiscoveryPersonalizationService`.
///
/// These functions decide *how* candidate media are scored and how diversity is
/// enforced in a carousel. They were moved out of the service verbatim so the
/// scoring algorithm can be exercised in isolation by unit tests (Fase 5 file-splitting,
/// same approach as `ListItemFilterer`). Behavior is preserved exactly, including the
/// small random jitter added to each score.
enum DiscoveryRanking {

    /// Compute the personalization score for a movie given the user's taste profile.
    ///
    /// The score is the sum of a deterministic component (genre match, preference
    /// strength, quality, popularity, recency) plus a bounded random jitter in `0...5`
    /// used to avoid a fully deterministic "filter bubble".
    static func personalizationScore(
        movie: Movie,
        userProfile: UserProfile
    ) -> Double {
        var score = 0.0

        // Genre match (0-50 points)
        let genreMatches = movie.genreIds?.filter { genreId in
            userProfile.topGenres.contains { $0.genreId == genreId }
        } ?? []
        score += Double(genreMatches.count) * 15.0

        // Genre preference strength (0-30 points)
        for genreId in movie.genreIds ?? [] {
            if let preference = userProfile.topGenres.first(where: { $0.genreId == genreId }) {
                score += preference.totalScore * 2.0
            }
        }

        // Quality score (0-20 points)
        score += movie.voteAverage * 2.0

        // Popularity factor (0-10 points)
        score += min(movie.popularity / 100.0, 10.0)

        // Recency bias (0-15 points) - prefer newer content
        if let releaseDate = movie.releaseDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: releaseDate) {
                let year = Calendar.current.component(.year, from: date)
                if year >= 2020 {
                    score += Double(year - 2020) * 2.0
                }
            }
        }

        // Diversity randomness (0-5 points)
        score += Double.random(in: 0...5)

        return score
    }

    /// Ensure diversity in recommendations to prevent a filter bubble.
    ///
    /// Walks the already-scored items in order, admitting an item only if none of its
    /// genres has already been admitted `maxPerGenre` times. Stops once `maxItems`
    /// items have been admitted.
    static func ensureDiversity<T: MovieProtocol>(
        _ items: [ScoredItem<T>],
        maxPerGenre: Int,
        maxItems: Int
    ) -> [ScoredItem<T>] {
        var result: [ScoredItem<T>] = []
        var genreCounts: [Int: Int] = [:]

        for item in items {
            let genres = item.item.genreIds ?? []

            // Check if adding this item would exceed genre limit
            var canAdd = true
            for genre in genres {
                if genreCounts[genre, default: 0] >= maxPerGenre {
                    canAdd = false
                    break
                }
            }

            if canAdd {
                result.append(item)
                for genre in genres {
                    genreCounts[genre, default: 0] += 1
                }
            }

            if result.count >= maxItems {
                break
            }
        }

        return result
    }

    /// Cosine similarity between two embedding vectors. Compares only the overlapping
    /// prefix (`min(a.count, b.count)`) and returns `0` for empty/zero-norm inputs.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }

        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = (sqrt(normA) * sqrt(normB))
        if denom == 0 { return 0 }
        return dot / denom
    }

    /// Stable de-duplication of movies by `id`, preserving first-seen order.
    static func deduplicateMoviesById(_ movies: [Movie]) -> [Movie] {
        var seen: Set<Int> = []
        var result: [Movie] = []
        result.reserveCapacity(movies.count)

        for movie in movies {
            if seen.insert(movie.id).inserted {
                result.append(movie)
            }
        }
        return result
    }

    /// Collect every distinct movie across the given carousels, by `id`, in first-seen order.
    static func collectUniqueMovies(from carousels: [PersonalizedCarousel]) -> [Movie] {
        var seen = Set<Int>()
        var result: [Movie] = []
        for carousel in carousels {
            for movie in carousel.items where seen.insert(movie.id).inserted {
                result.append(movie)
            }
        }
        return result
    }
}
