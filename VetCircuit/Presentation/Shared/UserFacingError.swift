import Foundation

/// Turns any error into something worth showing a person.
///
/// `error.localizedDescription` was surfaced directly in 103 places. For a
/// `DomainError` that is fine — it is `LocalizedError` and its messages were
/// written for people. For everything else it is not: a dropped connection
/// arrives as "The operation couldn't be completed. (NSURLErrorDomain error
/// -1009.)", which tells somebody nothing they can act on and reads like the
/// app leaking its insides.
///
/// Apple's guidance on feedback is that an error should say what happened and
/// what to do next. So the rule here is: keep the message when it was written
/// for a human, translate it when it was not, and always leave the person
/// with a next step rather than a code.
enum UserFacingError {
    static func message(for error: Error) -> String {
        // Written for people already — don't paraphrase it.
        if let domain = error as? DomainError, let described = domain.errorDescription {
            return described
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "That took too long. Check your connection and try again."
            case .networkConnectionLost:
                return "The connection dropped partway through. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "We can't reach VetCircuit right now. Try again in a moment."
            case .dataNotAllowed:
                return "Mobile data is off for this app. Turn it on in Settings, or connect to Wi-Fi."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "We couldn't make a secure connection. Try again, and avoid public Wi-Fi if this keeps happening."
            default:
                return "Something went wrong reaching VetCircuit. Try again in a moment."
            }
        }

        // A decoding failure means the server sent something this build does
        // not understand — never the person's fault, and never their problem
        // to decipher.
        if error is DecodingError {
            return "We got an unexpected response. Try again, and update the app if this keeps happening."
        }

        // Last resort. Deliberately not the raw description: anything that
        // reaches here is a type we did not anticipate, and its
        // `localizedDescription` is far more likely to be developer text than
        // something a customer can use.
        return "Something went wrong. Please try again."
    }
}
