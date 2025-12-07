import Foundation

/// Service for fetching streaming availability, pricing, and quality data from Movie of the Night API (via RapidAPI)
class WatchmodeService {
    @MainActor static let shared = WatchmodeService()
    
    private let baseURL = "https://streaming-availability.p.rapidapi.com"
    private let rapidAPIKey = "4f23d6c502msh1c6ccc90b956bb3p18cabcjsn051c85bd5b33"
    private let rapidAPIHost = "streaming-availability.p.rapidapi.com"
    private let session: URLSession
    private let cache: URLCache
    
    private init() {
        let config = URLSessionConfiguration.default
        cache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 50_000_000)
        config.urlCache = cache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }
    
    /// Fetch streaming sources with pricing for a movie/TV show
    nonisolated(nonsending)
    func getStreamingSources(tmdbId: Int, type: MediaType, region: String) async throws -> [WatchmodeSource] {
        // Movie of the Night API uses TMDb IDs directly - no conversion needed!
        return try await fetchSources(tmdbId: tmdbId, type: type, region: region)
    }
    
    /// Fetch streaming sources with pricing from Movie of the Night API
    nonisolated(nonsending)
    private func fetchSources(tmdbId: Int, type: MediaType, region: String) async throws -> [WatchmodeSource] {
        // Build endpoint: /shows/{type}/{tmdb_id}
        let typeString = type == .movie ? "movie" : "series"
        let endpoint = "\(baseURL)/shows/\(typeString)/\(tmdbId)"
        
        guard var components = URLComponents(string: endpoint) else {
            throw WatchmodeError.invalidURL
        }
        
        // Add country parameter
        components.queryItems = [
            URLQueryItem(name: "country", value: region.lowercased())
        ]
        
        guard let url = components.url else {
            throw WatchmodeError.invalidURL
        }
        
        print("🔍 [StreamingAvailability] Fetching sources: \(url.absoluteString)")
        
        // Create request with RapidAPI headers
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rapidAPIKey, forHTTPHeaderField: "X-RapidAPI-Key")
        request.setValue(rapidAPIHost, forHTTPHeaderField: "X-RapidAPI-Host")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchmodeError.invalidResponse
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            if let responseString = String(data: data, encoding: .utf8) {
                print("❌ [StreamingAvailability] Error (\(httpResponse.statusCode)): \(responseString)")
            }
            throw WatchmodeError.httpError(httpResponse.statusCode)
        }
        
        // Decode the Movie of the Night response
        let showResponse = try JSONDecoder().decode(StreamingAvailabilityShow.self, from: data)
        
        // Convert streaming options to WatchmodeSource format
        var sources: [WatchmodeSource] = []
        
        // API returns country codes in lowercase (e.g., "it", not "IT")
        if let streamingOptions = showResponse.streamingOptions?[region.lowercased()] {
            for option in streamingOptions {
                // Use addon name if it's an addon type, otherwise use service name
                let displayName: String
                if option.type == "addon", let addon = option.addon {
                    displayName = addon.name
                } else {
                    displayName = option.service.name
                }
                
                // Map type to TMDb-compatible format
                // "addon" and "subscription" -> "sub" (flatrate)
                // "buy" -> "buy"
                // "rent" -> "rent"
                // "free" -> "sub"
                let mappedType: String
                switch option.type {
                case "addon", "subscription", "free":
                    mappedType = "sub"
                case "buy":
                    mappedType = "buy"
                case "rent":
                    mappedType = "rent"
                default:
                    mappedType = option.type
                }
                
                let source = WatchmodeSource(
                    sourceId: option.service.id.hashValue,
                    name: displayName,
                    type: mappedType,
                    region: region,
                    webUrl: option.link,
                    format: option.quality,
                    price: option.price?.amountDouble,
                    currency: option.price?.currency,
                    androidUrl: option.link,
                    iosUrl: option.link
                )
                sources.append(source)
            }
        }
        
        print("✅ [StreamingAvailability] Fetched \(sources.count) sources for tmdbId=\(tmdbId) in region=\(region)")
        sources.forEach { source in
            print("   - \(source.name) (\(source.type)) | Price: \(source.formattedPrice ?? "nil") | Quality: \(source.formattedQuality ?? "nil")")
        }
        
        return sources
    }
}

// MARK: - Models

/// Movie of the Night API response model
struct StreamingAvailabilityShow: Codable {
    let streamingOptions: [String: [StreamingOption]]?
}

struct StreamingOption: Codable {
    let service: StreamingService
    let type: String // "addon", "subscription", "rent", "buy", "free"
    let link: String
    let quality: String? // "sd", "hd", "uhd"
    let price: StreamingPrice?
    let addon: StreamingAddon?
    
    enum CodingKeys: String, CodingKey {
        case service, type, link, quality, price, addon
    }
}

struct StreamingService: Codable {
    let id: String
    let name: String
    let homePage: String?
    let themeColorCode: String?
    let imageSet: ImageSet?
}

struct StreamingAddon: Codable {
    let id: String
    let name: String
    let homePage: String?
    let themeColorCode: String?
    let imageSet: ImageSet?
}

struct ImageSet: Codable {
    let lightThemeImage: String?
    let darkThemeImage: String?
    let whiteImage: String?
}

struct StreamingPrice: Codable {
    let amount: String // API returns string, not double
    let currency: String
    let formatted: String
    
    var amountDouble: Double? {
        Double(amount)
    }
}

struct WatchmodeSource: Codable {
    let sourceId: Int
    let name: String
    let type: String // "sub" (subscription), "rent", "buy", "free"
    let region: String
    let webUrl: String?
    let format: String? // "SD", "HD", "4K"
    let price: Double?
    let currency: String?
    let androidUrl: String?
    let iosUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case sourceId = "source_id"
        case name, type, region, format, price, currency
        case webUrl = "web_url"
        case androidUrl = "android_url"
        case iosUrl = "ios_url"
    }
    
    var formattedPrice: String? {
        guard let price = price, let currency = currency else {
            return nil
        }
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        
        if let formatted = formatter.string(from: NSNumber(value: price)) {
            return formatted
        }
        
        return "\(currency) \(String(format: "%.2f", price))"
    }
    
    var formattedQuality: String? {
        guard let format = format else { return nil }
        
        let uppercased = format.uppercased()
        if uppercased.contains("4K") || uppercased.contains("UHD") {
            return "4K"
        } else if uppercased.contains("HD") || uppercased.contains("1080") {
            return "HD"
        } else if uppercased.contains("SD") || uppercased.contains("480") {
            return "SD"
        }
        
        return format
    }
}

enum WatchmodeError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    case titleNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .titleNotFound:
            return "Title not found in Watchmode database"
        }
    }
}
