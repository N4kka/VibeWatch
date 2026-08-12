import Foundation

/// Raccomandazione estratta dal blocco vibe-json della risposta del modello, prima della
/// risoluzione TMDB.
struct AIParsedRecommendation: Equatable {
    let title: String
    let year: Int?
    let mediaType: MediaType
    let reason: String
    /// Confidence del modello clampata nel range 55–97; 75 se assente.
    let confidence: Int
}

/// Risposta del modello separata in parte conversazionale e raccomandazioni strutturate.
struct ParsedAIReply: Equatable {
    let text: String
    let recommendations: [AIParsedRecommendation]
}

/// Estrae il contratto vibe-json dalle risposte di Vibe AI. Qualsiasi malformazione degrada a
/// testo semplice: il parser non produce mai un errore visibile all'utente.
enum AIResponseParser {

    static let defaultConfidence = 75
    static let confidenceRange = 55...97

    static func parse(_ raw: String) -> ParsedAIReply {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Blocchi fenced ```vibe-json / ```json / ``` — vince l'ultimo che decodifica.
        if let (range, recs) = lastDecodableFencedBlock(in: cleaned), !recs.isEmpty {
            return reply(strippingRange: range, from: cleaned, recommendations: recs)
        }

        // 2. Fallback: l'ultimo array JSON top-level non fenced che decodifica.
        if let (range, recs) = lastDecodableBareArray(in: cleaned), !recs.isEmpty {
            return reply(strippingRange: range, from: cleaned, recommendations: recs)
        }

        return ParsedAIReply(text: cleaned, recommendations: [])
    }

    // MARK: - Fenced blocks

    private static func lastDecodableFencedBlock(in text: String) -> (Range<String.Index>, [AIParsedRecommendation])? {
        let pattern = "```(?:vibe-json|json)?[ \\t]*\\n?([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for match in regex.matches(in: text, range: fullRange).reversed() {
            guard let blockRange = Range(match.range, in: text),
                  let innerRange = Range(match.range(at: 1), in: text) else { continue }
            if let recs = decodeRecommendations(String(text[innerRange])) {
                return (blockRange, recs)
            }
        }
        return nil
    }

    // MARK: - Bare arrays

    private static func lastDecodableBareArray(in text: String) -> (Range<String.Index>, [AIParsedRecommendation])? {
        // Scansione a parentesi bilanciate degli array top-level, dall'ultimo al primo.
        var candidates: [Range<String.Index>] = []
        var depth = 0
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if char == "[" {
                if depth == 0 { start = index }
                depth += 1
            } else if char == "]" {
                depth = max(0, depth - 1)
                if depth == 0, let s = start {
                    candidates.append(s..<text.index(after: index))
                    start = nil
                }
            }
            index = text.index(after: index)
        }

        for range in candidates.reversed() {
            if let recs = decodeRecommendations(String(text[range])) {
                return (range, recs)
            }
        }
        return nil
    }

    // MARK: - Decoding

    /// Decodifica tollerante: year come Int o String, confidence opzionale, item con type ignoto
    /// scartati. Ritorna nil se il JSON non è un array di raccomandazioni plausibile.
    private static func decodeRecommendations(_ jsonString: String) -> [AIParsedRecommendation]? {
        guard let data = jsonString.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !array.isEmpty else { return nil }

        let recs = array.compactMap { item -> AIParsedRecommendation? in
            guard let title = item["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let mediaType: MediaType
            switch (item["type"] as? String)?.lowercased() {
            case "movie": mediaType = .movie
            case "tv", "show", "series": mediaType = .tv
            default: return nil
            }

            let year: Int?
            if let y = item["year"] as? Int {
                year = y
            } else if let s = item["year"] as? String, let y = Int(s.prefix(4)) {
                year = y
            } else {
                year = nil
            }

            let rawConfidence = (item["confidence"] as? Int)
                ?? (item["confidence"] as? Double).map(Int.init)
                ?? defaultConfidence
            let confidence = min(max(rawConfidence, confidenceRange.lowerBound), confidenceRange.upperBound)

            let reason = (item["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return AIParsedRecommendation(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                year: year,
                mediaType: mediaType,
                reason: reason,
                confidence: confidence
            )
        }

        // Un array che non contiene nessuna raccomandazione valida non è il nostro contratto
        // (es. un array di numeri): meglio lasciarlo nel testo.
        return recs.isEmpty ? nil : recs
    }

    private static func reply(
        strippingRange range: Range<String.Index>,
        from text: String,
        recommendations: [AIParsedRecommendation]
    ) -> ParsedAIReply {
        var remainder = text
        remainder.removeSubrange(range)
        let conversational = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedAIReply(text: conversational, recommendations: recommendations)
    }
}
