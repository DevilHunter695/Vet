import Testing
import Foundation
@testable import VetCircuit

/// The mapper exists so that nothing a person reads is developer text. These
/// pin the two halves of that promise: messages written for people survive
/// unchanged, and everything else is translated rather than leaked.
struct UserFacingErrorTests {
    @Test("a domain error's own wording is kept, not paraphrased")
    func domainErrorPassesThrough() {
        #expect(UserFacingError.message(for: DomainError.slotUnavailable)
                == "That time slot is no longer available.")
        #expect(UserFacingError.message(for: DomainError.validation("Pick a pet first."))
                == "Pick a pet first.")
    }

    @Test("being offline says so, and says what to do about it")
    func offlineIsPlainLanguage() {
        let message = UserFacingError.message(for: URLError(.notConnectedToInternet))
        #expect(message.contains("offline"))
        #expect(message.lowercased().contains("try again"))
        // The thing this whole type exists to prevent.
        #expect(!message.contains("NSURLError"))
        #expect(!message.contains("-1009"))
    }

    @Test("no network error leaks a code or a domain name to the user")
    func networkErrorsNeverLeakCodes() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .dataNotAllowed, .secureConnectionFailed, .badServerResponse
        ]
        for code in codes {
            let message = UserFacingError.message(for: URLError(code))
            #expect(!message.contains("NSURLError"), "URLError.\(code) leaked a domain name")
            #expect(!message.contains("Error Domain"), "URLError.\(code) leaked a domain name")
            #expect(!message.isEmpty)
            // Every one of these is recoverable, so every one says so.
            #expect(message.lowercased().contains("try again") || message.lowercased().contains("settings"),
                    "URLError.\(code) tells somebody what went wrong but not what to do: \(message)")
        }
    }

    @Test("an unexpected error type is translated, never printed raw")
    func unknownErrorsAreNotLeaked() {
        struct InternalFailure: Error { let detail = "index out of range in ledger reducer" }
        let message = UserFacingError.message(for: InternalFailure())
        #expect(!message.contains("ledger reducer"))
        #expect(message == "Something went wrong. Please try again.")
    }

    @Test("a decoding failure blames the response, not the person")
    func decodingErrorIsHonest() {
        let error = DecodingError.keyNotFound(
            CodingKeys.missing,
            .init(codingPath: [], debugDescription: "no such key")
        )
        let message = UserFacingError.message(for: error)
        #expect(!message.contains("no such key"))
        #expect(message.lowercased().contains("unexpected response"))
    }

    private enum CodingKeys: String, CodingKey { case missing }
}
