import ArgumentParser
import Foundation

/// Full ingestion pipeline: Harvest -> Validate -> Store
struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Full content ingestion pipeline: harvest, validate, and store clips"
    )

    @Option(name: .long, help: "Number of movies to process")
    var movies: Int = 100

    @Option(name: .long, help: "Number of TV shows to process")
    var shows: Int = 50

    @Option(name: .long, help: "Maximum clips to validate per title")
    var clipsPerTitle: Int = 3

    @Flag(name: .long, help: "Dry run - don't save to database")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Skip harvesting, only process existing cache")
    var skipHarvest: Bool = false

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    func run() async throws {
        print("🚀 VibeWatch Content Ingestion Pipeline")
        print("=".padding(toLength: 50, withPad: "=", startingAt: 0))

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
        let validator = YouTubeValidator(apiKey: config.youtubeAPIKey)
        var validationStats = ValidationStats()
        var validClips: [ClipRecord] = []

        // Phase 1: Harvest content from TMDB
        var harvestedMovies: [TMDBMovie] = []
        var harvestedShows: [TMDBTVShow] = []

        if !skipHarvest {
            print("\n📽️  Phase 1: Harvesting content from TMDB...")

            if movies > 0 {
                print("  Fetching \(movies) movies...")
                harvestedMovies = try await harvester.harvestMovies(count: movies) { current, total in
                    if current % 50 == 0 || current == total {
                        print("    Movies: \(current)/\(total)")
                    }
                }
                print("  ✅ Harvested \(harvestedMovies.count) movies")
            }

            if shows > 0 {
                print("  Fetching \(shows) TV shows...")
                harvestedShows = try await harvester.harvestTVShows(count: shows) { current, total in
                    if current % 50 == 0 || current == total {
                        print("    Shows: \(current)/\(total)")
                    }
                }
                print("  ✅ Harvested \(harvestedShows.count) TV shows")
            }
        }

        // Phase 2: Fetch and validate clips
        print("\n🎬 Phase 2: Fetching and validating clips...")

        // Process movies
        for (index, movie) in harvestedMovies.enumerated() {
            if verbose {
                print("  Processing: \(movie.title)")
            }

            do {
                let videosResponse = try await harvester.fetchMovieVideos(movieId: movie.id)
                let youtubeClips = videosResponse.results
                    .filter { $0.isYouTube && $0.isClipOrTrailer }
                    .prefix(clipsPerTitle)

                if youtubeClips.isEmpty { continue }

                let videoIds = youtubeClips.map(\.key)
                let results = try await validator.validateBatch(videoIds: Array(videoIds))

                for (clip, result) in zip(youtubeClips, results) {
                    validationStats.record(result)

                    if result.isValid, let duration = result.duration {
                        let record = createClipRecord(
                            from: clip,
                            movie: movie,
                            duration: duration,
                            blockedRegions: result.blockedRegions,
                            language: result.language
                        )
                        validClips.append(record)
                    }
                }
            } catch {
                if verbose {
                    print("    ⚠️ Error fetching clips: \(error.localizedDescription)")
                }
            }

            if (index + 1) % 20 == 0 {
                print("  Processed \(index + 1)/\(harvestedMovies.count) movies...")
            }
        }

        // Process TV shows
        for (index, show) in harvestedShows.enumerated() {
            if verbose {
                print("  Processing: \(show.name)")
            }

            do {
                let videosResponse = try await harvester.fetchTVShowVideos(tvShowId: show.id)
                let youtubeClips = videosResponse.results
                    .filter { $0.isYouTube && $0.isClipOrTrailer }
                    .prefix(clipsPerTitle)

                if youtubeClips.isEmpty { continue }

                let videoIds = youtubeClips.map(\.key)
                let results = try await validator.validateBatch(videoIds: Array(videoIds))

                for (clip, result) in zip(youtubeClips, results) {
                    validationStats.record(result)

                    if result.isValid, let duration = result.duration {
                        let record = createClipRecord(
                            from: clip,
                            tvShow: show,
                            duration: duration,
                            blockedRegions: result.blockedRegions,
                            language: result.language
                        )
                        validClips.append(record)
                    }
                }
            } catch {
                if verbose {
                    print("    ⚠️ Error fetching clips: \(error.localizedDescription)")
                }
            }

            if (index + 1) % 20 == 0 {
                print("  Processed \(index + 1)/\(harvestedShows.count) TV shows...")
            }
        }

        // Phase 3: Store valid clips
        print("\n💾 Phase 3: Storing valid clips...")
        print("  Found \(validClips.count) valid clips")

        if !dryRun && !validClips.isEmpty {
            try await storeClips(validClips, config: config)
            print("  ✅ Clips stored to Supabase")
        } else if dryRun {
            print("  🔍 Dry run - clips not stored")
            printSampleClips(validClips)
        }

        // Summary
        print("\n" + "=".padding(toLength: 50, withPad: "=", startingAt: 0))
        print("📊 Ingestion Summary")
        validationStats.printSummary()
        print("\n  Movies processed: \(harvestedMovies.count)")
        print("  TV shows processed: \(harvestedShows.count)")
        print("  Valid clips found: \(validClips.count)")
        print("  YouTube API quota: \(await validator.getQuotaUsed()) units")
        print("\n✨ Ingestion complete!")
    }

    // MARK: - Clip Record Creation

    private func createClipRecord(
        from clip: TMDBVideo,
        movie: TMDBMovie,
        duration: Int,
        blockedRegions: [String]?,
        language: String?
    ) -> ClipRecord {
        let genres = TMDBGenre.names(for: movie.genreIds, type: .movie)

        return ClipRecord(
            id: UUID().uuidString,
            clipId: "tmdb_movie_\(movie.id)_\(clip.key)",
            videoId: clip.key,
            title: clip.name,
            description: movie.overview,
            videoUrl: "https://www.youtube.com/watch?v=\(clip.key)",
            thumbnailUrl: "https://img.youtube.com/vi/\(clip.key)/maxresdefault.jpg",
            movieId: movie.id,
            tvShowId: nil,
            mediaType: "movie",
            genres: genres,
            actors: [],
            mood: nil,
            keywords: [],
            likes: 0,
            comments: 0,
            views: 0,
            durationSeconds: duration,
            isActive: true,
            isPremium: false,
            availableRegions: nil,
            blockedRegions: blockedRegions,
            primaryLanguage: language ?? clip.iso639_1,
            primaryRegion: clip.iso3166_1,
            validatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func createClipRecord(
        from clip: TMDBVideo,
        tvShow: TMDBTVShow,
        duration: Int,
        blockedRegions: [String]?,
        language: String?
    ) -> ClipRecord {
        let genres = TMDBGenre.names(for: tvShow.genreIds, type: .tv)

        return ClipRecord(
            id: UUID().uuidString,
            clipId: "tmdb_tv_\(tvShow.id)_\(clip.key)",
            videoId: clip.key,
            title: clip.name,
            description: tvShow.overview,
            videoUrl: "https://www.youtube.com/watch?v=\(clip.key)",
            thumbnailUrl: "https://img.youtube.com/vi/\(clip.key)/maxresdefault.jpg",
            movieId: nil,
            tvShowId: tvShow.id,
            mediaType: "tv",
            genres: genres,
            actors: [],
            mood: nil,
            keywords: [],
            likes: 0,
            comments: 0,
            views: 0,
            durationSeconds: duration,
            isActive: true,
            isPremium: false,
            availableRegions: nil,
            blockedRegions: blockedRegions,
            primaryLanguage: language ?? clip.iso639_1,
            primaryRegion: clip.iso3166_1,
            validatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - Database Operations

    private func storeClips(_ clips: [ClipRecord], config: ToolConfig) async throws {
        guard let url = URL(string: "\(config.supabaseURL)/rest/v1/clips") else {
            throw HarvesterError.invalidURL(config.supabaseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()

        // Batch insert (50 at a time)
        for batch in clips.chunked(into: 50) {
            let jsonData = try encoder.encode(batch)
            request.httpBody = jsonData

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("    ⚠️ Failed to save batch")
                continue
            }
        }
    }

    private func printSampleClips(_ clips: [ClipRecord]) {
        print("\n  Sample clips:")
        for clip in clips.prefix(5) {
            print("    - \(clip.title)")
            print("      Video: \(clip.videoId) | Duration: \(formatDuration(clip.durationSeconds))")
            print("      Genres: \(clip.genres.joined(separator: ", "))")
            if let blockedRegions = clip.blockedRegions, !blockedRegions.isEmpty {
                print("      Blocked in: \(blockedRegions.prefix(5).joined(separator: ", "))")
            }
        }
        if clips.count > 5 {
            print("    ... and \(clips.count - 5) more")
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
