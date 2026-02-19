import ArgumentParser
import Foundation

/// Command to harvest movies and TV shows from TMDB
struct HarvestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harvest",
        abstract: "Harvest movies and TV shows from TMDB API"
    )

    @Option(name: .long, help: "Number of movies to harvest")
    var movies: Int = 1000

    @Option(name: .long, help: "Number of TV shows to harvest")
    var shows: Int = 500

    @Flag(name: .long, help: "Also fetch video clips for each title")
    var withClips: Bool = false

    @Flag(name: .long, help: "Dry run - don't save to database")
    var dryRun: Bool = false

    func run() async throws {
        print("🎬 VibeWatch TMDB Harvester")
        print("=" .padding(toLength: 50, withPad: "=", startingAt: 0))

        // Load configuration
        let config: ToolConfig
        do {
            config = try ToolConfig.load()
            print("✅ Configuration loaded")
        } catch {
            print("❌ \(error.localizedDescription)")
            print("\nSet these environment variables:")
            print("  export TMDB_API_KEY=your_key")
            print("  export YOUTUBE_API_KEY=your_key")
            print("  export SUPABASE_URL=your_url")
            print("  export SUPABASE_SERVICE_KEY=your_service_key")
            throw ExitCode.failure
        }

        let harvester = TMDBHarvester(apiKey: config.tmdbAPIKey)

        // Harvest movies
        if movies > 0 {
            print("\n📽️  Harvesting \(movies) movies...")
            let harvestedMovies = try await harvester.harvestMovies(count: movies) { current, total in
                if current % 100 == 0 || current == total {
                    print("  Progress: \(current)/\(total) movies")
                }
            }
            print("✅ Harvested \(harvestedMovies.count) unique movies")

            if !dryRun {
                print("💾 Saving movies to Supabase...")
                try await saveMovies(harvestedMovies, config: config)
                print("✅ Movies saved")
            } else {
                print("🔍 Dry run - movies not saved")
                printSampleMovies(harvestedMovies)
            }

            // Fetch clips if requested
            if withClips {
                print("\n🎥 Fetching video clips for movies...")
                let clips = try await fetchClipsForMovies(harvestedMovies, harvester: harvester)
                print("✅ Found \(clips.count) video clips")

                if !dryRun {
                    print("💾 Saving clips to Supabase...")
                    // Clips will be validated and saved in the ingest command
                }
            }
        }

        // Harvest TV shows
        if shows > 0 {
            print("\n📺 Harvesting \(shows) TV shows...")
            let harvestedShows = try await harvester.harvestTVShows(count: shows) { current, total in
                if current % 100 == 0 || current == total {
                    print("  Progress: \(current)/\(total) shows")
                }
            }
            print("✅ Harvested \(harvestedShows.count) unique TV shows")

            if !dryRun {
                print("💾 Saving TV shows to Supabase...")
                try await saveTVShows(harvestedShows, config: config)
                print("✅ TV shows saved")
            } else {
                print("🔍 Dry run - TV shows not saved")
                printSampleTVShows(harvestedShows)
            }
        }

        print("\n✨ Harvest complete!")
    }

    // MARK: - Database Operations

    private func saveMovies(_ movies: [TMDBMovie], config: ToolConfig) async throws {
        // Use Supabase client to save movies
        guard let url = URL(string: "\(config.supabaseURL)/rest/v1/discovery_cache") else {
            throw HarvesterError.invalidURL(config.supabaseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(config.supabaseKey, forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

        // Convert movies to database format
        let records = movies.map { movie -> [String: Any] in
            [
                "id": UUID().uuidString,
                "content_type": "movie",
                "tmdb_id": movie.id,
                "title": movie.title,
                "overview": movie.overview,
                "poster_path": movie.posterPath as Any,
                "backdrop_path": movie.backdropPath as Any,
                "vote_average": movie.voteAverage,
                "release_date": movie.releaseDate as Any,
                "genres": movie.genreIds,
                "cached_at": ISO8601DateFormatter().string(from: Date()),
                "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 60 * 60))
            ]
        }

        // Batch insert (100 at a time)
        for batch in records.chunked(into: 100) {
            let jsonData = try JSONSerialization.data(withJSONObject: batch)
            request.httpBody = jsonData

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("⚠️ Failed to save batch")
                continue
            }
        }
    }

    private func saveTVShows(_ shows: [TMDBTVShow], config: ToolConfig) async throws {
        guard let url = URL(string: "\(config.supabaseURL)/rest/v1/discovery_cache") else {
            throw HarvesterError.invalidURL(config.supabaseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(config.supabaseKey, forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

        let records = shows.map { show -> [String: Any] in
            [
                "id": UUID().uuidString,
                "content_type": "tv",
                "tmdb_id": show.id,
                "title": show.name,
                "overview": show.overview,
                "poster_path": show.posterPath as Any,
                "backdrop_path": show.backdropPath as Any,
                "vote_average": show.voteAverage,
                "release_date": show.firstAirDate as Any,
                "genres": show.genreIds,
                "cached_at": ISO8601DateFormatter().string(from: Date()),
                "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 60 * 60))
            ]
        }

        for batch in records.chunked(into: 100) {
            let jsonData = try JSONSerialization.data(withJSONObject: batch)
            request.httpBody = jsonData

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("⚠️ Failed to save batch")
                continue
            }
        }
    }

    private func fetchClipsForMovies(_ movies: [TMDBMovie], harvester: TMDBHarvester) async throws -> [TMDBVideo] {
        var allClips: [TMDBVideo] = []

        for (index, movie) in movies.prefix(100).enumerated() {
            do {
                let response = try await harvester.fetchMovieVideos(movieId: movie.id)
                let youtubeClips = response.results.filter { $0.isYouTube && $0.isClipOrTrailer }
                allClips.append(contentsOf: youtubeClips)

                if (index + 1) % 20 == 0 {
                    print("  Fetched clips for \(index + 1) movies...")
                }
            } catch {
                // Continue on error
            }
        }

        return allClips
    }

    // MARK: - Debug Output

    private func printSampleMovies(_ movies: [TMDBMovie]) {
        print("\n  Sample movies:")
        for movie in movies.prefix(5) {
            let genres = TMDBGenre.names(for: movie.genreIds, type: .movie).joined(separator: ", ")
            print("    - \(movie.title) (\(movie.releaseDate ?? "N/A")) ⭐️ \(String(format: "%.1f", movie.voteAverage))")
            print("      Genres: \(genres)")
        }
        print("    ... and \(movies.count - 5) more")
    }

    private func printSampleTVShows(_ shows: [TMDBTVShow]) {
        print("\n  Sample TV shows:")
        for show in shows.prefix(5) {
            let genres = TMDBGenre.names(for: show.genreIds, type: .tv).joined(separator: ", ")
            print("    - \(show.name) (\(show.firstAirDate ?? "N/A")) ⭐️ \(String(format: "%.1f", show.voteAverage))")
            print("      Genres: \(genres)")
        }
        print("    ... and \(shows.count - 5) more")
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
