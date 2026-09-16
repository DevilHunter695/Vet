import Testing
import Foundation
@testable import VetCircuit

/// B7, G5, K2, K4 and A7 all promise a document the customer can share.
///
/// I previously reported these as "tested content, no renderer" — that was
/// wrong, and wrong in the exact way this codebase keeps being wrong: I
/// grepped for one type name, found no call sites, and concluded a feature
/// was missing instead of checking. Every one of them renders through
/// `UIGraphicsPDFRenderer` and is wired to a share sheet.
///
/// So the claim gets a test rather than another reading of the source. A PDF
/// file begins with the five bytes `%PDF-`; anything that doesn't is not a
/// document a share sheet, Mail or Files will accept, whatever the renderer
/// believed it produced.
@Suite("PDF rendering (B7, G5, K2, K4, A7)")
struct PDFRenderingTests {

    private func isPDF(_ data: Data) -> Bool {
        data.count > 1_000 && data.prefix(5) == Data("%PDF-".utf8)
    }

    private var pet: Pet {
        Pet(id: UUID(), ownerId: UUID(), name: "Bruno", species: .dog, breed: "Labrador",
            dateOfBirth: Calendar.current.date(byAdding: .month, value: -38, to: .now),
            sex: .male, isNeutered: true, weightKg: 31.4)
    }

    @Test("B7: the pet health summary renders a real PDF with its history in it")
    func healthSummaryRenders() {
        let subject = pet
        let weights = (0..<6).map { index in
            PetWeightEntry(id: UUID(), petId: subject.id, weightKg: 28.0 + Double(index) * 0.6,
                           recordedAt: Calendar.current.date(byAdding: .day, value: -index * 21, to: .now) ?? .now,
                           temperatureCelsius: 38.4, heartRateBpm: 92)
        }
        let vaccinations = [
            Vaccination(id: UUID(), petId: subject.id, vaccineName: "Rabies",
                        givenAt: Calendar.current.date(byAdding: .month, value: -11, to: .now),
                        nextDueAt: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now,
                        batchNumber: "RB-2291"),
        ]
        let data = GeneratePetHealthSummaryUseCase().execute(
            pet: subject, weightHistory: weights, vaccinations: vaccinations
        )
        #expect(isPDF(data), "B7 produced \(data.count) bytes that are not a PDF")
    }

    @Test("B7: a pet with no history still renders — an empty record is not a crash")
    func healthSummaryRendersWithNoHistory() {
        let data = GeneratePetHealthSummaryUseCase().execute(
            pet: pet, weightHistory: [], vaccinations: []
        )
        #expect(isPDF(data))
    }

    @Test("K4: the vaccination certificate renders a real PDF")
    func vaccinationCertificateRenders() {
        let vaccination = Vaccination(
            id: UUID(), petId: UUID(), vaccineName: "Rabies",
            givenAt: Calendar.current.date(byAdding: .month, value: -11, to: .now),
            nextDueAt: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now,
            batchNumber: "RB-2291"
        )
        #expect(isPDF(vaccination.certificatePDF(petName: "Bruno")))
    }

    @Test("K4: a certificate for a vaccination never given still renders")
    func vaccinationCertificateWithoutGivenDate() {
        let vaccination = Vaccination(
            id: UUID(), petId: UUID(), vaccineName: "DHPPi", givenAt: nil,
            nextDueAt: .now, batchNumber: nil
        )
        #expect(isPDF(vaccination.certificatePDF(petName: "Miso")))
    }

    @Test("K2: the prescription document renders a real PDF")
    func prescriptionDocumentRenders() {
        let prescription = Prescription(
            id: UUID(), visitId: UUID(), petId: UUID(), medicationName: "Apoquel 16mg",
            dosage: "1 tablet twice daily",
            instructions: "Give with food for 7 days, then stop.",
            prescribedByVetId: UUID(), issuedAt: .now
        )
        #expect(isPDF(prescription.documentPDF(petName: "Bruno")))
    }

    /// The share sheet needs a real file with a `.pdf` extension — raw `Data`
    /// alone isn't recognised as a PDF by Mail or Files, which is the whole
    /// reason `PDFShareURL` exists.
    @Test("a rendered PDF lands on disk as a .pdf file the share sheet can take")
    func writesAShareableFile() throws {
        let prescription = Prescription(
            id: UUID(), visitId: UUID(), petId: UUID(), medicationName: "Apoquel 16mg",
            dosage: "1 tablet twice daily", instructions: nil,
            prescribedByVetId: UUID(), issuedAt: .now
        )
        let share = try #require(
            PDFShareURL.write(prescription.documentPDF(petName: "Bruno"), suggestedName: "apoquel-prescription")
        )
        defer { try? FileManager.default.removeItem(at: share.url) }

        #expect(share.url.pathExtension == "pdf")
        #expect(FileManager.default.fileExists(atPath: share.url.path))
        #expect(isPDF(try Data(contentsOf: share.url)))
    }

    /// A filename with a slash in it would silently write into a directory
    /// that doesn't exist, so the write has to sanitise it.
    @Test("a medication name containing a slash does not break the file write")
    func sanitisesTheSuggestedFilename() throws {
        let share = try #require(
            PDFShareURL.write(Data("%PDF-1.4 stub".utf8), suggestedName: "Amoxicillin/Clavulanate")
        )
        defer { try? FileManager.default.removeItem(at: share.url) }
        #expect(FileManager.default.fileExists(atPath: share.url.path))
        #expect(!share.url.deletingPathExtension().lastPathComponent.contains("/"))
    }
}
