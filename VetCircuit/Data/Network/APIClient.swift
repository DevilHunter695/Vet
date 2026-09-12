import Foundation

// MARK: - Endpoint definitions (no magic strings scattered across the app)

enum Endpoint {
    case circuits(area: String?)
    case circuit(id: UUID)
    case createVisit
    case visits(userId: UUID)
    case visit(id: UUID)
    case updateVisitStatus(id: UUID)
    case paymentWebhook
    case checkoutVisit
    case checkoutSubscription
    case pets(ownerId: UUID)
    case chatHistory(visitId: UUID)
    case sendChat(visitId: UUID)
    case submitReview
    case registerDeviceToken

    var path: String {
        switch self {
        case .circuits: return "/v1/circuits"
        case .circuit(let id): return "/v1/circuits/\(id)"
        case .createVisit: return "/v1/visits"
        case .visits(let userId): return "/v1/users/\(userId)/visits"
        case .visit(let id): return "/v1/visits/\(id)"
        case .updateVisitStatus(let id): return "/v1/visits/\(id)/status"
        case .paymentWebhook: return "/v1/payments/webhook"
        case .checkoutVisit: return "/v1/payments/checkout/visit"
        case .checkoutSubscription: return "/v1/payments/checkout/subscription"
        case .pets(let ownerId): return "/v1/users/\(ownerId)/pets"
        case .chatHistory(let visitId): return "/v1/visits/\(visitId)/messages"
        case .sendChat(let visitId): return "/v1/visits/\(visitId)/messages"
        case .submitReview: return "/v1/reviews"
        case .registerDeviceToken: return "/v1/devices"
        }
    }

    var method: String {
        switch self {
        case .circuits, .circuit, .visits, .visit, .pets, .chatHistory:
            return "GET"
        case .createVisit, .paymentWebhook, .checkoutVisit, .checkoutSubscription, .sendChat, .submitReview, .registerDeviceToken:
            return "POST"
        case .updateVisitStatus:
            return "PATCH"
        }
    }
}

// MARK: - Token provider abstraction (Keychain-backed in production)

protocol TokenProviding: Sendable {
    func accessToken() async -> String?
    func refreshToken() async -> String?
    func store(access: String, refresh: String) async
    func clear() async
}

actor KeychainTokenProvider: TokenProviding {
    private let keychain = KeychainStore()

    func accessToken() async -> String? { keychain.read(key: "vc.access_token") }
    func refreshToken() async -> String? { keychain.read(key: "vc.refresh_token") }

    func store(access: String, refresh: String) async {
        keychain.write(key: "vc.access_token", value: access)
        keychain.write(key: "vc.refresh_token", value: refresh)
    }

    func clear() async {
        keychain.delete(key: "vc.access_token")
        keychain.delete(key: "vc.refresh_token")
    }
}

// MARK: - Thin async APIClient wrapping URLSession

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProviding
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, tokenProvider: TokenProviding, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func request<Body: Encodable, Response: Decodable>(
        _ endpoint: Endpoint,
        body: Body? = nil,
        queryItems: [URLQueryItem] = [],
        allowRetry: Bool = true
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw DomainError.network("Invalid URL") }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DomainError.network("No response") }

        if http.statusCode == 401 && allowRetry {
            if await refreshTokenIfPossible() {
                return try await self.request(endpoint, body: body, queryItems: queryItems, allowRetry: false)
            }
            throw DomainError.notAuthenticated
        }

        guard (200...299).contains(http.statusCode) else {
            throw DomainError.network("Request failed with status \(http.statusCode)")
        }

        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }

    func request<Response: Decodable>(_ endpoint: Endpoint, queryItems: [URLQueryItem] = []) async throws -> Response {
        try await request(endpoint, body: Optional<EmptyBody>.none, queryItems: queryItems)
    }

    /// Retries the failed request once after refreshing the access token via the refresh token.
    private func refreshTokenIfPossible() async -> Bool {
        guard let refresh = await tokenProvider.refreshToken() else { return false }
        // In production this calls a dedicated refresh endpoint. Left as an
        // extension point since the concrete backend (Supabase vs custom) differs.
        _ = refresh
        return false
    }
}

struct EmptyBody: Encodable {}
struct EmptyResponse: Decodable {}
