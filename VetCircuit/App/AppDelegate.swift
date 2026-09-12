import UIKit

/// Bridges UIKit-only APNs callbacks into the SwiftUI app lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard let userId = UserDefaults.standard.string(forKey: "vc.current_user_id").flatMap(UUID.init) else { return }
        Task { @MainActor in
            PushNotificationManager.shared.didRegister(deviceToken: deviceToken, userId: userId)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal — push is best-effort re-engagement, not core functionality.
    }
}
