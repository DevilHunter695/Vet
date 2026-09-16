import Testing
import Foundation
@testable import VetCircuit

// O7: semantic-version comparison for the force-upgrade gate.

@Suite("RemoteAppConfig version comparison")
struct AppConfigVersionTests {
    @Test("numeric comparison beats string comparison — 1.10.0 is newer than 1.2.0")
    func numericNotLexicographic() {
        #expect(RemoteAppConfig.compareVersions("1.10.0", "1.2.0") == 1)
        #expect(RemoteAppConfig.compareVersions("1.2.0", "1.10.0") == -1)
    }

    @Test("equal versions compare equal")
    func equalVersions() {
        #expect(RemoteAppConfig.compareVersions("1.2.3", "1.2.3") == 0)
    }

    @Test("missing trailing components default to zero")
    func missingComponentsDefaultToZero() {
        #expect(RemoteAppConfig.compareVersions("1.2", "1.2.0") == 0)
        #expect(RemoteAppConfig.compareVersions("1.2.1", "1.2") == 1)
        #expect(RemoteAppConfig.compareVersions("2", "1.9.9") == 1)
    }

    @Test("isSupported is true when current version is >= minimum")
    func isSupportedAtOrAboveMinimum() {
        #expect(RemoteAppConfig.isSupported(currentVersion: "1.1", minSupportedVersion: "1.1"))
        #expect(RemoteAppConfig.isSupported(currentVersion: "1.10", minSupportedVersion: "1.9"))
        #expect(!RemoteAppConfig.isSupported(currentVersion: "1.0", minSupportedVersion: "1.1"))
    }

    @Test("non-numeric trailing garbage does not crash and treats as 0")
    func nonNumericComponentsAreTreatedAsZero() {
        #expect(RemoteAppConfig.compareVersions("1.2.beta", "1.2.0") == 0)
    }
}

@Suite("CheckAppConfigUseCase")
struct CheckAppConfigUseCaseTests {
    @Test("returns .ok when maintenance is off and version is supported")
    func returnsOkWhenHealthy() async {
        let repo = MockAppConfigRepository()
        await repo.setConfig(RemoteAppConfig(minSupportedVersion: "1.0", isMaintenanceMode: false, maintenanceMessage: nil))
        let useCase = CheckAppConfigUseCase(repository: repo)

        let gate = await useCase.execute(currentVersion: "1.1")
        #expect(gate == .ok)
    }

    @Test("returns .maintenance when the server flag is set, regardless of version")
    func returnsMaintenanceWhenFlagged() async {
        let repo = MockAppConfigRepository()
        await repo.setConfig(RemoteAppConfig(minSupportedVersion: "1.0", isMaintenanceMode: true, maintenanceMessage: "Back soon"))
        let useCase = CheckAppConfigUseCase(repository: repo)

        let gate = await useCase.execute(currentVersion: "9.9")
        #expect(gate == .maintenance(message: "Back soon"))
    }

    @Test("returns .forceUpgrade when the running version is below the server minimum")
    func returnsForceUpgradeWhenBelowMinimum() async {
        let repo = MockAppConfigRepository()
        await repo.setConfig(RemoteAppConfig(minSupportedVersion: "2.0", isMaintenanceMode: false, maintenanceMessage: nil))
        let useCase = CheckAppConfigUseCase(repository: repo)

        let gate = await useCase.execute(currentVersion: "1.5")
        #expect(gate == .forceUpgrade(minVersion: "2.0"))
    }

    @Test("fails open to .ok when the config endpoint is unreachable")
    func failsOpenOnError() async {
        let repo = ThrowingAppConfigRepository()
        let useCase = CheckAppConfigUseCase(repository: repo)

        let gate = await useCase.execute(currentVersion: "1.0")
        #expect(gate == .ok)
    }
}

private actor ThrowingAppConfigRepository: AppConfigRepository {
    func fetchConfig() async throws -> RemoteAppConfig {
        throw DomainError.network("unreachable")
    }
}

// O1: notification preferences default to on except promotions.

@Suite("ManageNotificationPreferencesUseCase")
struct ManageNotificationPreferencesUseCaseTests {
    @Test("a user with no saved preferences gets the safe default")
    func defaultsToSafeOptOut() async throws {
        let repo = MockNotificationPreferencesRepository()
        let useCase = ManageNotificationPreferencesUseCase(repository: repo)
        let userId = UUID()

        let preferences = try await useCase.load(userId: userId)
        #expect(preferences.bookingUpdates)
        #expect(preferences.chatMessages)
        #expect(preferences.vaccinationReminders)
        #expect(!preferences.promotions)
    }

    @Test("saved preferences round-trip")
    func savedPreferencesRoundTrip() async throws {
        let repo = MockNotificationPreferencesRepository()
        let useCase = ManageNotificationPreferencesUseCase(repository: repo)
        let userId = UUID()
        var preferences = NotificationPreferences(userId: userId)
        preferences.promotions = true
        preferences.chatMessages = false

        _ = try await useCase.save(preferences)
        let reloaded = try await useCase.load(userId: userId)

        #expect(reloaded.promotions)
        #expect(!reloaded.chatMessages)
    }
}

