import Foundation
import UserNotifications
import UIKit

/// Handles APNs registration and local re-engagement reminders (subscription
/// renewal, upcoming visit) per the plan's V2 push-based re-engagement item.
/// Remote pushes (booking confirmed, vet arriving, visit complete) are sent
/// server-side by a Supabase Edge Function triggered on the relevant table
/// change — this class only owns the client-side registration + local
/// scheduling half of that story.
@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private let pushTokenRepository = DependencyContainer.shared.pushTokenRepository

    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            // Non-fatal: booking still works without push, user just won't get
            // proactive "vet arriving" alerts until they grant permission.
        }
    }

    func didRegister(deviceToken: Data, userId: UUID) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Task {
            try? await pushTokenRepository.registerDeviceToken(token, userId: userId)
        }
    }

    /// Schedules a local reminder a few days before a subscription auto-renews.
    func scheduleRenewalReminder(subscription: Subscription) {
        let content = UNMutableNotificationContent()
        content.title = "Your VetCircuit plan renews soon"
        content.body = "Your \(subscription.planType.rawValue) plan renews on \(subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))."
        content.sound = .default

        guard let triggerDate = Calendar.current.date(byAdding: .day, value: -3, to: subscription.renewalDate),
              triggerDate > .now else { return }

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "renewal-\(subscription.id)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
