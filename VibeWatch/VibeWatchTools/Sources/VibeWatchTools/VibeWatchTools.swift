import ArgumentParser
import Foundation

/// VibeWatch Content Ingestion Tools
///
/// A command-line tool for populating the VibeWatch database with:
/// - Movies and TV shows from TMDB
/// - Validated YouTube clips
///
/// Usage:
///   vibewatch-tools harvest --movies 1000 --shows 500
///   vibewatch-tools ingest --validate --limit 100
///   vibewatch-tools validate --clip-id abc123
@main
struct VibeWatchTools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vibewatch-tools",
        abstract: "VibeWatch Content Ingestion Tools",
        version: "1.0.0",
        subcommands: [
            HarvestCommand.self,
            IngestCommand.self,
            ValidateCommand.self
        ],
        defaultSubcommand: HarvestCommand.self
    )
}

// MARK: - Configuration

struct ToolConfig {
    let tmdbAPIKey: String
    let youtubeAPIKey: String
    let supabaseURL: String
    let supabaseKey: String

    static func load() throws -> ToolConfig {
        // Load from environment variables
        guard let tmdbKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"],
              !tmdbKey.isEmpty else {
            throw ConfigError.missingKey("TMDB_API_KEY")
        }

        guard let youtubeKey = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"],
              !youtubeKey.isEmpty else {
            throw ConfigError.missingKey("YOUTUBE_API_KEY")
        }

        guard let supabaseURL = ProcessInfo.processInfo.environment["SUPABASE_URL"],
              !supabaseURL.isEmpty else {
            throw ConfigError.missingKey("SUPABASE_URL")
        }

        guard let supabaseKey = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_KEY"],
              !supabaseKey.isEmpty else {
            throw ConfigError.missingKey("SUPABASE_SERVICE_KEY (use service role key for admin access)")
        }

        return ToolConfig(
            tmdbAPIKey: tmdbKey,
            youtubeAPIKey: youtubeKey,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey
        )
    }
}

enum ConfigError: LocalizedError {
    case missingKey(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let key):
            return "Missing environment variable: \(key)"
        }
    }
}
