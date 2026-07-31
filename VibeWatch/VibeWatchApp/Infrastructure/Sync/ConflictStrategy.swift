import Foundation

// MARK: - ConflictStrategy

/// Defines the conflict resolution strategies used by the SyncEngine.
///
/// Each strategy determines how to resolve conflicts when local and remote
/// records differ during synchronization.
///
/// Strategy assignments (from sync design):
/// - `lists`, `list_items`: `.union` (never lose user content)
/// - `user_gamification`: `.maxWins` (XP should never decrease)
/// - `user_badges`: `.union` (never lose earned badges)
/// - `movie_reactions`: `.lastWriteWins` (user's latest intent)
/// - `unified_user_preferences`: `.weightedMerge` (combine device signals)
/// - `clips`: `.serverWins` (content is authoritative)
public enum ConflictStrategy: String, Sendable, Equatable {
    /// Merge items from both local and remote using union semantics.
    /// Items present in either source are kept.
    /// Used for: lists, list_items, user_badges
    case union

    /// Take the maximum value for numeric fields.
    /// Used for: user_gamification (XP, level, streaks)
    case maxWins

    /// Most recent timestamp wins.
    /// Used for: movie_reactions
    case lastWriteWins

    /// Always take the server/remote value.
    /// Used for: clips (content is authoritative)
    case serverWins

    /// Weighted merge for preferences, combining signals from multiple devices.
    /// Used for: unified_user_preferences
    case weightedMerge

    // MARK: - Strategy Descriptions

    /// Human-readable description of the strategy
    public var description: String {
        switch self {
        case .union:
            return "Merge items from both sources (never lose content)"
        case .maxWins:
            return "Take maximum value (XP/progress never decreases)"
        case .lastWriteWins:
            return "Most recent timestamp wins (latest user intent)"
        case .serverWins:
            return "Server is authoritative (content sync)"
        case .weightedMerge:
            return "Combine signals from multiple devices"
        }
    }
}

// MARK: - Table Strategy Mapping

/// Maps database tables to their conflict resolution strategies.
/// This implements the strategy table from the sync design document.
public enum TableConflictMapping {
    /// Returns the appropriate conflict strategy for a given table name.
    ///
    /// Strategy assignments:
    /// - `lists`, `list_items`: `.union` - Never lose user content
    /// - `user_gamification`: `.maxWins` - XP should never decrease
    /// - `user_badges`: `.union` - Never lose earned badges
    /// - `movie_reactions`: `.lastWriteWins` - User's latest intent
    /// - `unified_user_preferences`: `.weightedMerge` - Combine device signals
    /// - `clips`: `.serverWins` - Content is authoritative
    /// - Default: `.lastWriteWins` - Safe fallback for unknown tables
    public static func strategy(for table: String) -> ConflictStrategy {
        switch table {
        // Union strategy - never lose user content
        case "lists", "list_items":
            return .union

        // Max wins - XP/progress should never decrease
        case "user_gamification":
            return .maxWins

        // Union - never lose earned badges
        case "user_badges":
            return .union

        // Last write wins - user's latest intent
        case "movie_reactions":
            return .lastWriteWins

        // Weighted merge - combine device signals
        case "unified_user_preferences":
            return .weightedMerge

        // Server wins - content is authoritative
        case "clips":
            return .serverWins

        // SPEC v3 §4. Gli eventi sono append-only: non si perde mai una visione, e due dispositivi
        // che ne registrano di diversi li tengono entrambi.
        case "watch_events":
            return .union

        // Derivata dagli eventi e ricalcolata dal server (§1.1). Il client scrive solo
        // `user_status`, e lo fa via outbox: qui vince sempre ciò che arriva.
        case "tv_show_state":
            return .serverWins

        // Le due viste di §9.2 sono cache di righe già pronte per la schermata: nessuno in locale
        // le scrive mai, quindi non esiste un caso in cui la copia locale debba vincere. Erano
        // finite nel `default` (`lastWriteWins`), che le confronta per `updated_at` — e
        // `v_tv_timeline` un `updated_at` non ce l'ha nemmeno. Con `serverWins` la riga che arriva
        // sostituisce quella che c'è, che è l'unico comportamento sensato per uno specchio.
        case "v_tv_tracking", "v_tv_timeline":
            return .serverWins

        // SPEC v3 §4: un follow non si perde mai. Il soft delete e' l'unfollow e viaggia come
        // contenuto della riga, quindi l'union lo conserva come conserva il resto.
        case "user_follows":
            return .union

        // Default fallback for unknown tables
        default:
            return .lastWriteWins
        }
    }

    /// All tables with their assigned strategies
    public static let allMappings: [(table: String, strategy: ConflictStrategy)] = [
        ("lists", .union),
        ("list_items", .union),
        ("user_gamification", .maxWins),
        ("user_badges", .union),
        ("movie_reactions", .lastWriteWins),
        ("unified_user_preferences", .weightedMerge),
        ("clips", .serverWins)
    ]
}
