import Foundation

/// Backend configuration. No secrets are hardcoded here — API keys such as the
/// Supabase anon key are safe to ship client-side only because RLS enforces
/// authorization server-side; anything truly sensitive (service role keys,
/// payment gateway secrets) must never appear in the app bundle.
enum AppConfig {
    static var supabaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    /// Empty-string-is-nil, matching `supabaseURL` above. A build template
    /// that leaves the key blank rather than absent would otherwise report
    /// itself as configured and then fail every request with a 401 — the
    /// worst of both modes.
    static var supabaseAnonKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static var isBackendConfigured: Bool {
        supabaseURL != nil && supabaseAnonKey != nil
    }

    static let apiBaseURL = supabaseURL ?? URL(string: "https://example.invalid")!
}
