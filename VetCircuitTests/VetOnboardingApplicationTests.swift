import Testing
import Foundation
@testable import VetCircuit

// L2: document-backed vet onboarding — SubmitVetOnboardingApplicationUseCase
// validation. This exercises only the domain/data layer: this app has no
// vet-facing UI to submit a real application from.

@Suite("SubmitVetOnboardingApplicationUseCase")
struct SubmitVetOnboardingApplicationUseCaseTests {
    private func makeUseCase() -> (SubmitVetOnboardingApplicationUseCase, MockVetOnboardingRepository) {
        let repository = MockVetOnboardingRepository()
        return (SubmitVetOnboardingApplicationUseCase(repository: repository), repository)
    }

    private let sampleURL = URL(string: "mock-storage://onboarding/doc.pdf")!

    @Test("submits successfully when all five documents are present")
    func submitsWithAllDocuments() async throws {
        let (useCase, _) = makeUseCase()
        let applicantId = UUID()
        let application = try await useCase.submit(
            applicantUserId: applicantId,
            degreeDocumentURL: sampleURL, vciCertificateURL: sampleURL,
            idDocumentURL: sampleURL, policeVerificationURL: sampleURL, photoURL: sampleURL
        )
        #expect(application.applicantUserId == applicantId)
        #expect(application.status == .submitted)
        #expect(application.reviewedAt == nil)
    }

    @Test("rejects a submission missing the degree document")
    func rejectsMissingDegree() async {
        let (useCase, _) = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.submit(
                applicantUserId: UUID(),
                degreeDocumentURL: nil, vciCertificateURL: sampleURL,
                idDocumentURL: sampleURL, policeVerificationURL: sampleURL, photoURL: sampleURL
            )
        }
    }

    @Test("rejects a submission missing the VCI certificate")
    func rejectsMissingVCICertificate() async {
        let (useCase, _) = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.submit(
                applicantUserId: UUID(),
                degreeDocumentURL: sampleURL, vciCertificateURL: nil,
                idDocumentURL: sampleURL, policeVerificationURL: sampleURL, photoURL: sampleURL
            )
        }
    }

    @Test("rejects a submission missing the ID document")
    func rejectsMissingIDDocument() async {
        let (useCase, _) = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.submit(
                applicantUserId: UUID(),
                degreeDocumentURL: sampleURL, vciCertificateURL: sampleURL,
                idDocumentURL: nil, policeVerificationURL: sampleURL, photoURL: sampleURL
            )
        }
    }

    @Test("rejects a submission missing the police verification certificate")
    func rejectsMissingPoliceVerification() async {
        let (useCase, _) = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.submit(
                applicantUserId: UUID(),
                degreeDocumentURL: sampleURL, vciCertificateURL: sampleURL,
                idDocumentURL: sampleURL, policeVerificationURL: nil, photoURL: sampleURL
            )
        }
    }

    @Test("rejects a submission missing the photo")
    func rejectsMissingPhoto() async {
        let (useCase, _) = makeUseCase()
        await #expect(throws: DomainError.self) {
            try await useCase.submit(
                applicantUserId: UUID(),
                degreeDocumentURL: sampleURL, vciCertificateURL: sampleURL,
                idDocumentURL: sampleURL, policeVerificationURL: sampleURL, photoURL: nil
            )
        }
    }

    @Test("allows an update while the application is still submitted")
    func allowsUpdateWhileSubmitted() async throws {
        let (useCase, _) = makeUseCase()
        let applicantId = UUID()
        var application = try await useCase.submit(
            applicantUserId: applicantId,
            degreeDocumentURL: sampleURL, vciCertificateURL: sampleURL,
            idDocumentURL: sampleURL, policeVerificationURL: sampleURL, photoURL: sampleURL
        )
        let replacementURL = URL(string: "mock-storage://onboarding/replacement.pdf")!
        application.degreeDocumentURL = replacementURL
        let updated = try await useCase.update(application)
        #expect(updated.degreeDocumentURL == replacementURL)
    }

    @Test("rejects an update attempt once status has moved past submitted")
    func rejectsUpdateAfterStatusMovesOn() async throws {
        let (useCase, repository) = makeUseCase()
        let applicantId = UUID()
        var application = try await useCase.submit(
            applicantUserId: applicantId,
            degreeDocumentURL: sampleURL, vciCertificateURL: sampleURL,
            idDocumentURL: sampleURL, policeVerificationURL: sampleURL, photoURL: sampleURL
        )
        // Simulate ops moving the application into review, directly via the
        // repository (as an admin/ops action would, bypassing the use case's
        // applicant-facing update path).
        application.status = .underReview
        _ = try await repository.submit(application)

        application.reviewNotes = "trying to sneak in a change"
        await #expect(throws: DomainError.self) {
            try await useCase.update(application)
        }
    }

    @Test("the repository itself also refuses an update once status has moved past submitted")
    func repositoryRefusesUpdateAfterStatusMovesOn() async throws {
        let repository = MockVetOnboardingRepository()
        let applicantId = UUID()
        var application = VetOnboardingApplication(
            id: UUID(), applicantUserId: applicantId, degreeDocumentURL: sampleURL,
            vciCertificateURL: sampleURL, idDocumentURL: sampleURL, policeVerificationURL: sampleURL,
            photoURL: sampleURL, status: .approved, submittedAt: .now, reviewedAt: .now, reviewNotes: nil
        )
        _ = try await repository.submit(application)

        application.reviewNotes = "still shouldn't be editable"
        await #expect(throws: DomainError.self) {
            try await repository.update(application)
        }
    }
}
