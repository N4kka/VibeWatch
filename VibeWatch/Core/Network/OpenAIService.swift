import Foundation

class OpenAIService {
    static let shared = OpenAIService()
    
    private let apiKey = "" // TODO: Add your OpenAI API key
    private let baseURL = "https://api.openai.com/v1"
    
    private init() {}
    
    func generateClipDescription(movieTitle: String, sceneDescription: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw OpenAIError.notConfigured
        }
        
        let prompt = """
        Generate a short, engaging description (max 100 characters) for a video clip from the movie "\(movieTitle)".
        Scene: \(sceneDescription)
        
        The description should be catchy and make people want to watch the clip.
        """
        
        let request = OpenAIRequest(
            model: "gpt-3.5-turbo",
            messages: [
                OpenAIMessage(role: "system", content: "You are a creative video clip description writer."),
                OpenAIMessage(role: "user", content: prompt)
            ],
            maxTokens: 50
        )
        
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw OpenAIError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OpenAIError.invalidResponse
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        
        guard let content = openAIResponse.choices.first?.message.content else {
            throw OpenAIError.noContent
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int
    
    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }
}

struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

struct OpenAIResponse: Codable {
    let choices: [OpenAIChoice]
}

struct OpenAIChoice: Codable {
    let message: OpenAIMessage
}

enum OpenAIError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case noContent
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenAI is not configured. Please add your API key."
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .noContent:
            return "No content in response"
        }
    }
}
