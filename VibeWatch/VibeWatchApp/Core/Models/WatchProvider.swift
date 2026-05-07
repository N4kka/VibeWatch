import Foundation

// MARK: - Watch Provider Models

struct WatchProvider: Codable {
    let results: [String: CountryProviders]
}

struct CountryProviders: Codable {
    var flatrate: [Provider]?
    var rent: [Provider]?
    var buy: [Provider]?
    var link: String?

    var hasUsableProviders: Bool {
        flatrate?.contains(where: \.hasUsableLogo) == true ||
        rent?.contains(where: \.hasUsableLogo) == true ||
        buy?.contains(where: \.hasUsableLogo) == true
    }
}

struct Provider: Codable, Identifiable, Hashable {
    let providerId: Int
    let providerName: String
    let logoPath: String
    let displayPriority: Int
    var price: PriceInfo?
    var quality: String?
    var presentationType: String?
    var externalLink: URL?
    
    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case providerName = "provider_name"
        case logoPath = "logo_path"
        case displayPriority = "display_priority"
        case price
        case quality
        case presentationType = "presentation_type"
        case externalLink
    }
    
    var id: Int { providerId }

    var hasUsableLogo: Bool {
        guard !logoPath.isEmpty else { return false }
        let lowerLogo = logoPath.lowercased()
        if lowerLogo.contains(".svg") { return false }
        if lowerLogo.contains("logo-white") { return false }
        return true
    }
    
    var logoURL: URL {
        if logoPath.hasPrefix("http") {
            return URL(string: logoPath) ?? URL(string: "https://image.tmdb.org/t/p/original\(logoPath)")!
        }
        return URL(string: "https://image.tmdb.org/t/p/original\(logoPath)")!
    }
    
    var formattedQuality: String? {
        guard let quality = quality else { return nil }
        
        // Map common formats to user-friendly names
        switch quality.lowercased() {
        case "4k", "uhd", "2160p":
            return "4K"
        case "hd", "1080p", "bluray":
            return "HD"
        case "sd", "480p", "dvd":
            return "SD"
        default:
            return quality.uppercased()
        }
    }
}

struct PriceInfo: Codable, Hashable {
    let value: Double
    let currency: String
    let formatted: String?
    
    var displayPrice: String {
        if let formatted = formatted {
            return formatted
        }
        
        // Fallback formatting
        let symbol: String
        switch currency.uppercased() {
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        case "JPY": symbol = "¥"
        default: symbol = currency
        }
        
        return "\(symbol)\(String(format: "%.2f", value))"
    }
}

// Note: WatchmodeSource and WatchmodeResponse are defined in Core/Network/WatchmodeService.swift
