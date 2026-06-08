import Foundation

/// Pure XP → level math, shared as the single source of truth for the leveling curve.
///
/// This exact curve was duplicated verbatim in `UserGamificationState` (GamificationService)
/// and in `ConflictResolver`; both now delegate here (Fase 5 file-splitting / de-dup,
/// same approach as `ListItemFilterer`). Behavior is preserved exactly.
///
/// `LevelCalculator` in `LevelProgressView` also derives its XP brackets from this curve,
/// so the level-progress UI stays consistent with the user's actual `currentLevel`.
enum GamificationLeveling {

    /// Cumulative XP required to *reach* a given level (exponential growth curve).
    static func threshold(for level: Int) -> Int {
        switch level {
        case 1: return 0
        case 2...5: return (level - 1) * 100
        case 6...10: return 500 + (level - 5) * 300
        case 11...15: return 2000 + (level - 10) * 600
        case 16...20: return 5000 + (level - 15) * 1000
        case 21...25: return 10000 + (level - 20) * 2000
        case 26...30: return 20000 + (level - 25) * 4000
        case 31...40: return 40000 + (level - 30) * 4000
        default: return 80000 + (level - 40) * 5000
        }
    }

    /// The level corresponding to a given total XP, capped at level 50.
    static func level(forTotalXP xp: Int) -> Int {
        var level = 1
        while threshold(for: level + 1) <= xp && level < 50 {
            level += 1
        }
        return level
    }
}
