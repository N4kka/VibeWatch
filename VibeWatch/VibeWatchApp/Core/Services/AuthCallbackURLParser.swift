import Foundation

/// Pure parsing of Supabase auth callback URLs (recovery / OAuth redirects).
///
/// Extracted verbatim from `AuthService` (`combinedQueryItems`, `moveFragmentToQueryIfNeeded`,
/// and the recovery-detection predicates) so the fiddly query/fragment handling can be
/// unit-tested without the service or network (Fase 5 file-splitting). Side effects
/// (logging, user-facing toasts) stay in the `AuthService` wrappers; only the parsing and
/// the boolean decisions live here. Behavior preserved exactly.
enum AuthCallbackURLParser {

    /// Combine query items from both the query string and the fragment (`#…`) portion,
    /// supporting Supabase OAuth/recovery redirects that put tokens in the fragment.
    static func combinedQueryItems(from url: URL) -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query = components?.queryItems {
            items.append(contentsOf: query)
        }

        if let fragment = components?.fragment,
           let fragComponents = URLComponents(string: "?\(fragment)"),
           let fragItems = fragComponents.queryItems {
            items.append(contentsOf: fragItems)
        }

        return items
    }

    /// Supabase sometimes returns tokens in the fragment; move them into the query string
    /// so downstream parsing works. Returns the URL unchanged when there is no fragment.
    static func moveFragmentToQueryIfNeeded(_ url: URL) -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              !fragment.isEmpty,
              var merged = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var queryItems = merged.queryItems ?? []
        if let fragComponents = URLComponents(string: "?\(fragment)"),
           let fragItems = fragComponents.queryItems {
            queryItems.append(contentsOf: fragItems)
        }
        merged.fragment = nil
        merged.queryItems = queryItems
        return merged.url ?? url
    }

    /// True when the callback carries `type=recovery` (password-recovery flow).
    static func isPasswordRecovery(_ url: URL) -> Bool {
        combinedQueryItems(from: url).contains { $0.name == "type" && $0.value == "recovery" }
    }

    /// True when the user should be shown the "link invalid/expired" message:
    /// either a recovery link or an `error_code=otp_expired`.
    static func shouldShowRecoveryError(from url: URL) -> Bool {
        let items = combinedQueryItems(from: url)
        let errorCode = items.first(where: { $0.name == "error_code" })?.value
        let isRecovery = items.contains(where: { $0.name == "type" && $0.value == "recovery" })
        return isRecovery || errorCode == "otp_expired"
    }
}
