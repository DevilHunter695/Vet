import Foundation

// MARK: - Deep links (plan §3 N7) — every campaign target needs a URL.
//
// Known architecture gap (plan §6.1): the plan calls for "a typed Route enum
// + NavigationStack(path:) per tab, driven by a Router", but MainTabView
// today (App/VetCircuitApp.swift) runs three independent NavigationStacks
// with no shared Router — there is nowhere to point an arbitrary deep link
// from outside those stacks. Rather than bolt a parallel, disconnected
// navigation system on top, this parser only produces a `Route` value; the
// app stores the pending route and the relevant tab consumes it on appear
// (see PendingDeepLinkStore in App/VetCircuitApp.swift). Wiring every tab's
// internal navigation to arbitrary deep-link targets (e.g. jumping straight
// into a specific visit's chat thread) needs the real Router first.

enum DeepLink: Equatable {
    case visit(UUID)
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
