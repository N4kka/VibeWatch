import Foundation

enum CerebrasError: Error {
    case invalidURL
    case noData
    case decodingError
    case serverError(String)
    case unknown
}

// Request Models
struct CerebrasChatRequest: Codable {
    let model: String
    let messages: [CerebrasMessage]
    let maxTokens: Int?
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case stream
    }
}

struct CerebrasMessage: Codable {
    let role: String
    let content: String
}

// Response Models
struct CerebrasChatResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [CerebrasChoice]
    let usage: CerebrasUsage?
}

struct CerebrasChoice: Codable {
    let index: Int
    let message: CerebrasMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct CerebrasUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

class CerebrasService {
    @MainActor static let shared = CerebrasService()
    
    private let baseURL = "https://api.cerebras.ai/v1/chat/completions"
    // Llama 3.1 8B is a good default for speed/efficiency on the free tier
    private let defaultModel = "llama3.1-8b" 
    
    private init() {}
    
    /// Sends a chat prompt to the Cerebras API
    /// - Parameters:
    ///   - prompt: The user's input string
    ///   - systemPrompt: Optional system instruction to guide the AI's behavior
    ///   - model: The model to use (defaults to llama3.1-8b)
    /// - Returns: The AI's string response
    func generateResponse(
        prompt: String,
        systemPrompt: String = "You are a helpful assistant for a movie and TV show discovery app called VibeWatch.",
        model: String? = nil
    ) async throws -> CerebrasChatResponse { // Return CerebrasChatResponse
        
        guard let url = URL(string: baseURL) else {
            throw CerebrasError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(Config.cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let messages = [
            CerebrasMessage(role: "system", content: systemPrompt),
            CerebrasMessage(role: "user", content: prompt)
        ]
        
        let requestBody = CerebrasChatRequest(
            model: model ?? defaultModel,
            messages: messages,
            maxTokens: 1024, // Adjust as needed
            temperature: 0.7,
            stream: false
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw CerebrasError.decodingError // Encoding error actually, but mapping to generic error
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CerebrasError.unknown
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: data, encoding: .utf8) {
                throw CerebrasError.serverError(errorString)
            }
            throw CerebrasError.serverError("Status code: \(httpResponse.statusCode)")
        }
        
        do {
            let decodedResponse = try JSONDecoder().decode(CerebrasChatResponse.self, from: data)
            return decodedResponse // Return the full response
        } catch {
            print("Cerebras Decoding Error: \(error)")
            throw CerebrasError.decodingError
        }
    }
}
