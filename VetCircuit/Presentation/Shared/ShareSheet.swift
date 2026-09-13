import SwiftUI

/// B7: thin `UIActivityViewController` wrapper so a use case's plain `Data`
/// (a generated PDF, say) can be handed to the iOS share sheet from SwiftUI.
/// No SwiftUI-native equivalent exists that lets a data blob (rather than a
/// file already on disk) be shared directly, so this stays a UIKit bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
