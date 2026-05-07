import ArgumentParser
import Foundation

/// Command to validate YouTube clips
struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate YouTube video clips for embedding"
    )

    @Option(name: .long, help: "Single YouTube video ID to validate")
    var videoId: String?

    @Option(name: .long, help: "File containing video IDs (one per line)")
    var file: String?

    @Option(name: .long, help: "TMDB movie ID to fetch and validate clips for")
    var movieId: Int?

    @Option(name: .long, help: "TMDB TV show ID to fetch and validate clips for")
    var tvShowId: Int?

    @Flag(name: .long, help: "Show detailed validation results")
    var verbose: Bool = false

    func run() async throws {
        print("🔍 VibeWatch Clip Validator")
        print("=".padding(toLength: 50, withPad: "=", startingAt: 0))

        // Load configuration
        let config: ToolConfig
        do {
            config = try ToolConfig.load()
            print("✅ Configuration loaded")
        } catch {
            print("❌ \(error.localizedDescription)")
            print("\nSet these environment variables:")
            print("  export YOUTUBE_API_KEY=your_key")
            print("  export TMDB_API_KEY=your_key (for --movie-id/--tv-show-id)")
            throw ExitCode.failure
        }

        let validator = YouTubeValidator(apiKey: config.youtubeAPIKey)
        var stats = ValidationStats()

        // Validate based on input type
        if let videoId = videoId {
            // Single video validation
            print("\n📹 Validating video: \(videoId)")
            let result = try await validator.validate(videoId: videoId)
            stats.record(result)
            printResult(result, verbose: true)

        } else if let filePath = file {
            // Batch validation from file
            let videoIds = try loadVideoIds(from: filePath)
            print("\n📁 Validating \(videoIds.count) videos from file...")

            // Batch validate (50 at a time for efficiency)
            for batch in videoIds.chunked(into: 50) {
                let results = try await validator.validateBatch(videoIds: batch)
                for result in results {
                    stats.record(result)
                    if verbose {
                        printResult(result, verbose: false)
                    }
                }
            }

        } else if let movieId = movieId {
            // Fetch clips from TMDB movie and validate
            print("\n🎬 Fetching clips for movie ID: \(movieId)")
            let harvester = TMDBHarvester(apiKey: config.tmdbAPIKey)
            let videosResponse = try await harvester.fetchMovieVideos(movieId: movieId)
            let youtubeClips = videosResponse.results.filter { $0.isYouTube && $0.isClipOrTrailer }

            print("  Found \(youtubeClips.count) YouTube clips")

            if !youtubeClips.isEmpty {
                let videoIds = youtubeClips.map(\.key)
                let results = try await validator.validateBatch(videoIds: videoIds)

                for (clip, result) in zip(youtubeClips, results) {
                    stats.record(result)
                    if verbose {
                        print("\n  \(clip.name) (\(clip.type))")
                    }
                    printResult(result, verbose: verbose)
                }
            }

        } else if let tvShowId = tvShowId {
            // Fetch clips from TMDB TV show and validate
            print("\n📺 Fetching clips for TV show ID: \(tvShowId)")
            let harvester = TMDBHarvester(apiKey: config.tmdbAPIKey)
            let videosResponse = try await harvester.fetchTVShowVideos(tvShowId: tvShowId)
            let youtubeClips = videosResponse.results.filter { $0.isYouTube && $0.isClipOrTrailer }

            print("  Found \(youtubeClips.count) YouTube clips")

            if !youtubeClips.isEmpty {
                let videoIds = youtubeClips.map(\.key)
                let results = try await validator.validateBatch(videoIds: videoIds)

                for (clip, result) in zip(youtubeClips, results) {
                    stats.record(result)
                    if verbose {
                        print("\n  \(clip.name) (\(clip.type))")
                    }
                    printResult(result, verbose: verbose)
                }
            }

        } else {
            print("❌ Please specify one of: --video-id, --file, --movie-id, or --tv-show-id")
            throw ExitCode.failure
        }

        // Print statistics
        stats.printSummary()
        print("\n📊 YouTube API quota used: \(await validator.getQuotaUsed()) units")
    }

    // MARK: - Helpers

    private func loadVideoIds(from path: String) throws -> [String] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func printResult(_ result: ClipValidationResult, verbose: Bool) {
        if result.isValid {
            var details = "✅ \(result.videoId)"
            if let duration = result.duration {
                details += " (\(formatDuration(duration)))"
            }
            if let blockedRegions = result.blockedRegions, !blockedRegions.isEmpty {
                details += " [blocked: \(blockedRegions.prefix(3).joined(separator: ","))...]"
            }
            print("  \(details)")
        } else {
            print("  ❌ \(result.videoId): \(result.reason ?? "Unknown reason")")
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
