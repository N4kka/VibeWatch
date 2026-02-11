import Foundation

// MARK: - Phase 5: Secure Logging

/// Secure logger that sanitizes sensitive data in DEBUG builds
/// and completely silences output in RELEASE builds
enum Logger {

    // MARK: - Sensitive Data Patterns

    /// Patterns to redact from log messages
    private static let sensitivePatterns: [(pattern: String, replacement: String)] = [
        // Email addresses
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[EMAIL_REDACTED]"),
        // API keys (common formats)
        (#"(api[_-]?key|apikey)[=:]\s*['\"]?[\w-]{20,}['\"]?"#, "[API_KEY_REDACTED]"),
        // Bearer tokens
        (#"Bearer\s+[\w.-]+"#, "Bearer [TOKEN_REDACTED]"),
        // JWT tokens (3 base64 segments separated by dots)
        (#"eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+"#, "[JWT_REDACTED]"),
        // UUID patterns that might be user IDs
        (#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, "[UUID_REDACTED]"),
        // Password fields
        (#"(password|passwd|pwd)[=:]\s*['\"]?[^'\"\\s]+['\"]?"#, "[PASSWORD_REDACTED]"),
        // Secret/token fields
        (#"(secret|token)[=:]\s*['\"]?[\w-]{10,}['\"]?"#, "[SECRET_REDACTED]")
    ]

    /// Compiled regex patterns (lazy initialization for performance)
    private static let sensitiveRegexes: [(regex: NSRegularExpression, replacement: String)] = {
        sensitivePatterns.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            return (regex, replacement)
        }
    }()

    // MARK: - Sanitization

    /// Sanitize a message by redacting sensitive data
    private static func sanitize(_ message: String) -> String {
        var sanitized = message
        for (regex, replacement) in sensitiveRegexes {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: replacement)
        }
        return sanitized
    }

    // MARK: - Logging Methods

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        #if DEBUG
        let filename = (file as NSString).lastPathComponent
        let sanitized = sanitize(message)
        print("🔍 [\(filename):\(line)] \(sanitized)")
        #endif
    }

    static func info(_ message: String) {
        #if DEBUG
        let sanitized = sanitize(message)
        print("ℹ️ \(sanitized)")
        #endif
    }

    static func warning(_ message: String) {
        #if DEBUG
        let sanitized = sanitize(message)
        print("⚠️ \(sanitized)")
        #endif
    }

    static func error(_ message: String, error: Error? = nil) {
        #if DEBUG
        let sanitized = sanitize(message)
        if let error = error {
            print("❌ \(sanitized): \(error.localizedDescription)")
        } else {
            print("❌ \(sanitized)")
        }
        #endif
    }

    // MARK: - Secure Print Wrapper

    /// Production-safe print wrapper - only outputs in DEBUG builds
    /// Use this instead of print() for app-level logging
    static func log(_ message: String, prefix: String = "📱") {
        #if DEBUG
        let sanitized = sanitize(message)
        print("\(prefix) \(sanitized)")
        #endif
    }

    /// Log with a specific category/tag
    static func log(_ message: String, category: String) {
        #if DEBUG
        let sanitized = sanitize(message)
        print("[\(category)] \(sanitized)")
        #endif
    }
}