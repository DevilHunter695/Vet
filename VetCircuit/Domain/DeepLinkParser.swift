import Foundation

// MARK: - Deep links (plan §3 N7) — every campaign target needs a URL.
//
// `App/Router.swift` now owns turning one of these into an actual tab
// switch plus (on the Visits/Profile tabs) a typed `Route` pushed onto that
// tab's `NavigationPath` — see its doc comment for exactly which tabs were
// converted and why the Book tab still resolves `.book` itself.

enum DeepLink: Equatable {
    case visit(UUID)
    /// `vetcircuit://visit/<uuid>/chat` — jumps straight into that visit's
    /// chat thread instead of only its detail screen. This is the exact
    /// "unreachable from outside" case plan §6.1 called out before the
    /// Router existed.
    case chat(visitId: UUID)
    case book(circuitId: UUID)
    case household
    case unknown
}

/// Pure URL parsing — no networking, no UIKit/SwiftUI. Accepts both the
/// custom scheme (`vetcircuit://visit/<uuid>`) and an eventual universal
/// link path (`https://vetcircuit.app/visit/<uuid>`) with the same layout,
/// since both forms carry the same host+path shape once the scheme differs.
enum DeepLinkParser {
    static func parse(_ url: URL) -> DeepLink {
        // `vetcircuit://visit/<uuid>` puts "visit" in .host, not the first
        // path component — URLComponents treats the segment right after
        // `scheme://` as host regardless of scheme, custom or not.
        let host = url.host?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "visit":
            guard let idString = pathComponents.first, let id = UUID(uuidString: idString) else { return .unknown }
            // `vetcircuit://visit/<uuid>/chat` — one segment further than
            // the plain visit-detail link.
            if pathComponents.count > 1, pathComponents[1] == "chat" {
                return .chat(visitId: id)
            }
            return .visit(id)
        case "book":
            guard let idString = pathComponents.first, let id = UUID(uuidString: idString) else { return .unknown }
            return .book(circuitId: id)
        case "household":
            return .household
        default:
            return .unknown
        }
    }
}
