import SwiftUI
@preconcurrency import WebKit

enum CheckoutLoadState: Equatable {
    case loading, loaded, failed
}

/// Renders the payment gateway's hosted checkout page (Razorpay/Stripe/UPI).
/// We never collect or see raw card data — the gateway's own page handles it,
/// so the app inherits their PCI compliance instead of needing its own.
struct CheckoutWebView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: CheckoutLoadState = .loading

    var body: some View {
        NavigationStack {
            ZStack {
                CheckoutWKWebView(url: url) { state in
                    withAnimation(Theme.crossFade) { loadState = state }
                }
                .opacity(loadState == .failed ? 0 : 1)

                if loadState == .loading {
                    ProgressView()
                        .transition(.opacity)
                }

                if loadState == .failed {
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Couldn't reach checkout",
                        message: "This may be a demo checkout link, or your connection dropped. Please try again in a moment.",
                        actionTitle: "Close"
                    ) { dismiss() }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct CheckoutWKWebView: UIViewRepresentable {
    let url: URL
    let onStateChange: (CheckoutLoadState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: onStateChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onStateChange: (CheckoutLoadState) -> Void

        init(onStateChange: @escaping (CheckoutLoadState) -> Void) {
            self.onStateChange = onStateChange
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onStateChange(.loaded)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStateChange(.failed)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStateChange(.failed)
        }
    }
}
