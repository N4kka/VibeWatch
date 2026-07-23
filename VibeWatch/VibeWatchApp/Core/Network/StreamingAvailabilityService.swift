import Foundation

protocol StreamingAvailabilityProviding: Sendable {
    func getProviders(tmdbId: Int, type: MediaType, region: String) async throws -> CountryProviders
}

/// Fetches comprehensive streaming availability, pricing and quality data — the "Movie of the
/// Night" service, reached through the `watch-providers` Edge Function rather than directly.
///
/// The service is metered at **1.000 requests/month** on the tier this project uses, shared by
/// ~305 users: roughly three lookups per user per month. Calling it from the device meant the same
/// title looked up on two phones cost two requests out of that allowance. The proxy caches each
/// answer for a week server-side, so one request now serves everyone, and it keeps the RapidAPI key
/// out of the app bundle where it was extractable from the IPA.
///
/// A failure here is soft by design: `LiveWatchProvidersRepository` falls back to TMDB's
/// watch/providers, losing the deep links and pricing this adds but not the provider list.
final class StreamingAvailabilityService: StreamingAvailabilityProviding {
    @MainActor static let shared = StreamingAvailabilityService()

    private let proxyURL: String = {
        let base = Config.supabaseURL
        guard !base.isEmpty else { return "" }
        let host = base.replacingOccurrences(of: ".supabase.co", with: ".functions.supabase.co")
        return "\(host)/watch-providers"
    }()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }
    
    /// Fetch comprehensive streaming providers for a movie/TV show
    nonisolated(nonsending)
    func getProviders(tmdbId: Int, type: MediaType, region: String) async throws -> CountryProviders {
        let sources = try await fetchSources(tmdbId: tmdbId, type: type, region: region)
        return mapToCountryProviders(sources, region: region)
    }
    
    /// Fetch streaming sources from Movie of the Night API
    /// Envelope returned by the `watch-providers` Edge Function. `show` is the upstream payload
    /// unchanged, or null when the title is not in the catalogue.
    private struct ProxyResponse: Decodable {
        let show: StreamingAvailabilityShow?
        let cached: Bool?
    }

    nonisolated(nonsending)
    private func fetchSources(tmdbId: Int, type: MediaType, region: String) async throws -> [WatchmodeSource] {
        guard !proxyURL.isEmpty, let url = URL(string: proxyURL) else {
            throw StreamingAvailabilityError.invalidURL
        }

        let body: [String: Any] = [
            "tmdbId": tmdbId,
            "mediaType": type == .movie ? "movie" : "series",
            "region": region.lowercased()
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.debug("[StreamingAvailability] Fetching providers for \(tmdbId) (\(region))")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingAvailabilityError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            // 429 covers both the per-caller rate limit and the exhausted monthly allowance; the
            // caller treats them the same way, by falling back to TMDB.
            if httpResponse.statusCode == 429 {
                Logger.warning("[StreamingAvailability] Rate limited or monthly quota exhausted")
                throw StreamingAvailabilityError.rateLimitExceeded
            }
            throw StreamingAvailabilityError.httpError(httpResponse.statusCode)
        }

        let proxyResponse = try JSONDecoder().decode(ProxyResponse.self, from: data)
        guard let show = proxyResponse.show else { return [] }
        return convertToSources(show, region: region)
    }
    
    private func convertToSources(_ response: StreamingAvailabilityShow, region: String) -> [WatchmodeSource] {
        var sources: [WatchmodeSource] = []
        
        // Debug: Print available regions
        if let optionsMap = response.streamingOptions {
            Logger.debug("[StreamingAvailability] Available regions in response: \(optionsMap.keys.joined(separator: ", "))")
        }
        
        // API returns country codes in lowercase
        guard let options = response.streamingOptions?[region.lowercased()] else {
            Logger.warning("[StreamingAvailability] No options found for region: \(region.lowercased())")
            return []
        }
        
        Logger.debug("[StreamingAvailability] Found \(options.count) options for \(region)")
        
        for option in options {
            let (displayName, logoUrl) = getServiceDetails(option)
            
            // Debug: Print details for every option found
            Logger.debug("[StreamingAvailability] Service: \(displayName), Type: \(option.type), Quality: \(option.quality ?? "nil"), Price: \(option.price?.amount ?? "nil"), Logo URL: \(logoUrl ?? "nil")")
            if let serviceImages = option.service.imageSet {
                Logger.debug("[StreamingAvailability] Service Images - Light: \(serviceImages.lightThemeImage ?? "nil"), Dark: \(serviceImages.darkThemeImage ?? "nil"), White: \(serviceImages.whiteImage ?? "nil")")
            }
            
            // Map types to internal format
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
                androidUrl: option.link, // API provides universal link
                iosUrl: option.link,     // API provides universal link
                logoUrl: logoUrl
            )
            sources.append(source)
        }
        
        return sources
    }
    
    private func getServiceDetails(_ option: StreamingOption) -> (String, String?) {
        // Try to get any available image
        if option.type == "addon", let addon = option.addon {
            let image = addon.imageSet?.darkThemeImage ?? 
                        addon.imageSet?.lightThemeImage ?? 
                        addon.imageSet?.whiteImage
            return (addon.name, image)
        } else {
            let image = option.service.imageSet?.darkThemeImage ?? 
                        option.service.imageSet?.lightThemeImage ?? 
                        option.service.imageSet?.whiteImage
            return (option.service.name, image)
        }
    }
    
    private func mapToCountryProviders(_ sources: [WatchmodeSource], region: String) -> CountryProviders {
        var flatrate: [Provider] = []
        var rent: [Provider] = []
        var buy: [Provider] = []
        
        for source in sources {
            let priceInfo: PriceInfo?
            if let price = source.price, let currency = source.currency {
                priceInfo = PriceInfo(
                    value: price,
                    currency: currency,
                    formatted: source.formattedPrice
                )
            } else {
                priceInfo = nil
            }
            
            let provider = Provider(
                providerId: source.sourceId,
                providerName: source.name,
                logoPath: source.logoUrl ?? "", // Model handles absolute URL check
                displayPriority: 0, // Not available in this API
                price: priceInfo,
                quality: source.formattedQuality,
                presentationType: source.formattedQuality,
                externalLink: URL(string: source.webUrl ?? "")
            )
            
            switch source.type {
            case "sub":
                flatrate.append(provider)
            case "rent":
                rent.append(provider)
            case "buy":
                buy.append(provider)
            default:
                break
            }
        }
        
        return CountryProviders(
            flatrate: flatrate.isEmpty ? nil : flatrate,
            rent: rent.isEmpty ? nil : rent,
            buy: buy.isEmpty ? nil : buy,
            link: nil // We don't need a JustWatch fallback link if we have data
        )
    }
}

// MARK: - Internal Models

enum StreamingAvailabilityError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case rateLimitExceeded
    case decodingError(Error)
    
    var errorDescription: String? {
        switch self {
        case .rateLimitExceeded: return "API Rate Limit Exceeded"
        default: return "Streaming Availability Error"
        }
    }
}

// Reuse existing models from previous WatchmodeService but updated for internal use
struct WatchmodeSource: Codable {
    let sourceId: Int
    let name: String
    let type: String
    let region: String
    let webUrl: String?
    let format: String?
    let price: Double?
    let currency: String?
    let androidUrl: String?
    let iosUrl: String?
    let logoUrl: String? // Added logo support
    
    var formattedPrice: String? {
        guard let price = price, let currency = currency else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: price))
    }
    
    var formattedQuality: String? {
        guard let format = format else { return nil }
        let uppercased = format.uppercased()
        if uppercased.contains("4K") || uppercased.contains("UHD") { return "4K" }
        if uppercased.contains("HD") || uppercased.contains("1080") { return "HD" }
        return "SD"
    }
}

// MARK: - API Response Models

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
