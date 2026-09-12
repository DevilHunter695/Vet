import SwiftUI
@preconcurrency import WebKit

/// Renders the payment gateway's hosted checkout page (Razorpay/Stripe/UPI).
/// We never collect or see raw card data — the gateway's own page handles it,
/// so the app inherits their PCI compliance instead of needing its own.
struct CheckoutWebView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(url: url)
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

private struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.load(URLRequest(url: url))
    }
}
