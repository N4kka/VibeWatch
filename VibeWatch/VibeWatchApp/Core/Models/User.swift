import Foundation

struct User: Identifiable, Codable {
    let id: String
    let email: String
    var displayName: String?
    var avatarURL: String?
    let createdAt: Date
    var updatedAt: Date
    
    // Cache preferences
    var cacheSizePreference: ImageCacheService.CacheSizePreference = .medium
    var imagePrefetchOption: ImageCacheService.ImagePrefetchOption = .wifiOnly
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case cacheSizePreference = "cache_size_preference"
        case imagePrefetchOption = "image_prefetch_option"
    }
    
    init(id: String, email: String, displayName: String? = nil, avatarURL: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), cacheSizePreference: ImageCacheService.CacheSizePreference = .medium, imagePrefetchOption: ImageCacheService.ImagePrefetchOption = .wifiOnly) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cacheSizePreference = cacheSizePreference
        self.imagePrefetchOption = imagePrefetchOption
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        
        // Handle dates that may come as ISO strings or native Date
        func decodeDate(for key: CodingKeys) throws -> Date {
            if let date = try? container.decode(Date.self, forKey: key) {
                return date
            }
            if let isoString = try? container.decode(String.self, forKey: key),
               let parsed = ISO8601DateFormatter().date(from: isoString) {
                return parsed
            }
            return Date()
        }
        
        createdAt = try decodeDate(for: .createdAt)
        updatedAt = try decodeDate(for: .updatedAt)
        
        // Try to decode preferences directly first
        if let preference = try? container.decode(ImageCacheService.CacheSizePreference.self, forKey: .cacheSizePreference) {
            cacheSizePreference = preference
        } else if let preferenceString = try? container.decode(String.self, forKey: .cacheSizePreference),
                  let preference = ImageCacheService.CacheSizePreference(rawValue: preferenceString) {
            cacheSizePreference = preference
        }
        
        // Try to decode prefetch option directly first
        if let option = try? container.decode(ImageCacheService.ImagePrefetchOption.self, forKey: .imagePrefetchOption) {
            imagePrefetchOption = option
        } else if let optionString = try? container.decode(String.self, forKey: .imagePrefetchOption),
                  let option = ImageCacheService.ImagePrefetchOption(rawValue: optionString) {
            imagePrefetchOption = option
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(email, forKey: .email)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(cacheSizePreference, forKey: .cacheSizePreference)
        try container.encode(imagePrefetchOption, forKey: .imagePrefetchOption)
    }
}
