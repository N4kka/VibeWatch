import Foundation
import SwiftUI

enum StreamingPlatform: String, CaseIterable, Identifiable, Codable {
    case netflix = "Netflix"
    case disney = "Disney+"
    case prime = "Prime Video"
    case sky = "Sky"
    case now = "Now"
    case hbo = "HBO Max"
    case apple = "Apple TV+"
    case paramount = "Paramount+"
    case hulu = "Hulu"
    case peacock = "Peacock"
    case showtime = "Showtime"
    case max = "Max"
    case pluto = "Pluto TV"
    case tubi = "Tubi"
    case crunchyroll = "Crunchyroll"
    case discoveryPlus = "Discovery+"
    case starz = "Starz"
    case mgmPlus = "MGM+"
    case amc = "AMC+"
    case mubi = "MUBI"
    case criterion = "Criterion"
    case britbox = "BritBox"
    case acorn = "Acorn TV"
    case shudder = "Shudder"
    case sundance = "Sundance Now"
    case curiosity = "CuriosityStream"
    case dazn = "DAZN"
    case fubo = "FuboTV"
    case sling = "Sling TV"
    case youtube = "YouTube TV"
    case plex = "Plex"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .netflix: return "play.rectangle.fill"
        case .disney: return "star.fill"
        case .prime: return "play.circle.fill"
        case .sky, .now: return "play.tv.fill"
        case .hbo, .max: return "h.square.fill"
        case .apple: return "applelogo"
        case .paramount: return "mountain.2.fill"
        case .hulu: return "play.tv.fill"
        case .peacock: return "bird.fill"
        case .showtime, .starz, .mgmPlus, .amc: return "tv.fill"
        case .pluto, .tubi: return "play.tv"
        case .crunchyroll: return "play.circle"
        case .discoveryPlus: return "d.circle.fill"
        case .mubi, .criterion: return "film.fill"
        case .britbox, .acorn: return "tv.circle.fill"
        case .shudder, .sundance: return "film"
        case .curiosity: return "lightbulb.fill"
        case .dazn, .fubo, .sling, .youtube: return "sportscourt.fill"
        case .plex: return "play.square.fill"
        }
    }
    
    var logoAssetName: String? {
        switch self {
        case .netflix: return "netflix_logo"
        case .disney: return "disney_plus_logo"
        case .prime: return "prime_video_logo"
        case .sky, .now: return nil
        case .hbo: return "hbo_logo"
        case .max: return "hbo_max_logo"
        case .apple: return "apple_tv_logo"
        case .paramount: return "paramount_logo"
        case .hulu: return "hulu_logo"
        case .peacock: return "peacock_logo"
        case .youtube: return "yt_logo"
        case .plex: return "plex_logo"
        default: return nil
        }
    }
    
    var color: Color {
        switch self {
        case .netflix: return Color(red: 0.9, green: 0.1, blue: 0.15)
        case .disney: return Color(red: 0.05, green: 0.2, blue: 0.5)
        case .prime: return Color(red: 0.0, green: 0.7, blue: 0.85)
        case .sky: return Color(red: 0.0, green: 0.45, blue: 0.82)
        case .now: return Color(red: 0.0, green: 0.68, blue: 0.32)
        case .hbo, .max: return Color(red: 0.4, green: 0.1, blue: 0.7)
        case .apple: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .paramount: return Color(red: 0.0, green: 0.4, blue: 0.8)
        case .hulu: return Color(red: 0.1, green: 0.8, blue: 0.4)
        case .peacock: return Color(red: 0.9, green: 0.6, blue: 0.0)
        case .showtime: return Color(red: 0.8, green: 0.0, blue: 0.0)
        case .pluto: return Color(red: 1.0, green: 0.4, blue: 0.0)
        case .tubi: return Color(red: 1.0, green: 0.2, blue: 0.4)
        case .crunchyroll: return Color(red: 1.0, green: 0.6, blue: 0.0)
        case .discoveryPlus: return Color(red: 0.0, green: 0.5, blue: 0.9)
        case .starz: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .mgmPlus: return Color(red: 0.8, green: 0.7, blue: 0.3)
        case .amc: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .mubi: return Color(red: 0.0, green: 0.4, blue: 0.9)
        case .criterion: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .britbox: return Color(red: 0.8, green: 0.1, blue: 0.2)
        case .acorn: return Color(red: 0.9, green: 0.5, blue: 0.1)
        case .shudder: return Color(red: 0.9, green: 0.2, blue: 0.2)
        case .sundance: return Color(red: 0.2, green: 0.5, blue: 0.7)
        case .curiosity: return Color(red: 0.9, green: 0.7, blue: 0.2)
        case .dazn: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .fubo: return Color(red: 0.0, green: 0.7, blue: 0.3)
        case .sling: return Color(red: 0.0, green: 0.4, blue: 0.9)
        case .youtube: return Color(red: 1.0, green: 0.0, blue: 0.0)
        case .plex: return Color(red: 0.9, green: 0.7, blue: 0.1)
        }
    }
}
