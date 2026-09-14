import UIKit
import SwiftUI

/// K2/K4: a generated PDF written to a temp file so it can be shared via
/// `UIActivityViewController` with a proper `.pdf` extension (raw `Data`
/// alone isn't recognized as a PDF by the share sheet) and drive a
/// `.sheet(item:)` presentation.
struct PDFShareURL: Identifiable {
    let id = UUID()
    let url: URL

    static func write(_ data: Data, suggestedName: String) -> PDFShareURL? {
        let safeName = suggestedName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-\(UUID().uuidString).pdf")
        do {
            try data.write(to: url)
            return PDFShareURL(url: url)
        } catch {
            return nil
        }
    }
}

/// K2/K4: a tiny native PDF renderer (`UIGraphicsPDFRenderer`, part of
/// UIKit — no third-party library or account needed) that turns a title +
/// a list of label/value rows into a single-page PDF. Used for the
/// vaccination certificate (K4) and the prescription document (K2), the
/// same "known gap, same shape as A7's export-PDF gap" this closes.
enum PDFDocumentBuilder {
    struct Row { let label: String; let value: String }

    static func render(title: String, subtitle: String? = nil, rows: [Row], footer: String? = nil) -> Data {
        let pageWidth: CGFloat = 612 // US Letter at 72 dpi
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 48
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = margin

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.black,
            ]
            (title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttrs)
            y += 32

            if let subtitle {
                let subtitleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray,
                ]
                (subtitle as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: subtitleAttrs)
                y += 28
            }

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: UIColor.black,
            ]
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.black,
            ]
            for row in rows {
                (row.label as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: labelAttrs)
                (row.value as NSString).draw(at: CGPoint(x: margin + 160, y: y), withAttributes: valueAttrs)
                y += 22
            }

            if let footer {
                y += 20
                let footerAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.italicSystemFont(ofSize: 11), .foregroundColor: UIColor.gray,
                ]
                (footer as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: footerAttrs)
            }
        }
    }
}

extension Vaccination {
    /// K4: a printable vaccination certificate — generated client-side from
    /// this app's own record, not fetched from anywhere.
    func certificatePDF(petName: String) -> Data {
        var rows: [PDFDocumentBuilder.Row] = [
            .init(label: "Pet", value: petName),
            .init(label: "Vaccine", value: vaccineName),
        ]
        if let givenAt { rows.append(.init(label: "Date given", value: givenAt.formatted(date: .long, time: .omitted))) }
        rows.append(.init(label: "Next due", value: nextDueAt.formatted(date: .long, time: .omitted)))
        if let batchNumber { rows.append(.init(label: "Batch number", value: batchNumber)) }
        return PDFDocumentBuilder.render(
            title: "Vaccination Certificate", subtitle: "VetCircuit — pet home-visit vet care", rows: rows,
            footer: "Generated from the vaccination record on file. Not a substitute for a vet-issued certificate where one is legally required."
        )
    }
}

extension DataExport {
    /// A7: DPDP data-principal export as a readable PDF, alongside the
    /// machine-readable JSON export — same `PDFDocumentBuilder` already
    /// used for K2/K4, so this closes the "no PDF" gap without a new
    /// rendering path.
    func summaryPDF() -> Data {
        var rows: [PDFDocumentBuilder.Row] = [
            .init(label: "Name", value: user.name),
        ]
        if let email = user.email { rows.append(.init(label: "Email", value: email)) }
        if let phone = user.phone { rows.append(.init(label: "Phone", value: phone)) }
        rows.append(.init(label: "Addresses on file", value: "\(addresses.count)"))
        rows.append(.init(label: "Visits on record", value: "\(visits.count)"))
        rows.append(.init(label: "Active consents", value: "\(consents.count)"))
        for visit in visits {
            rows.append(.init(
                label: "Visit \(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened))",
                value: visit.status.rawValue.capitalized
            ))
        }
        for consent in consents {
            rows.append(.init(
                label: "Consent: \(consent.purpose)",
                value: "granted \(consent.grantedAt.formatted(date: .abbreviated, time: .omitted))"
            ))
        }
        return PDFDocumentBuilder.render(
            title: "Your VetCircuit Data",
            subtitle: "Generated \(generatedAt.formatted(date: .long, time: .shortened))",
            rows: rows,
            footer: "A DPDP data-principal export. The full machine-readable record is also available as JSON."
        )
    }
}

extension Prescription {
    /// K2: a printable prescription document, structured from this app's
    /// own (vet-signed, server-recorded) record.
    func documentPDF(petName: String) -> Data {
        var rows: [PDFDocumentBuilder.Row] = [
            .init(label: "Pet", value: petName),
            .init(label: "Medication", value: medicationName),
            .init(label: "Dosage", value: dosage),
            .init(label: "Issued", value: issuedAt.formatted(date: .long, time: .omitted)),
        ]
        if let instructions { rows.append(.init(label: "Instructions", value: instructions)) }
        return PDFDocumentBuilder.render(
            title: "Prescription", subtitle: "VetCircuit — pet home-visit vet care", rows: rows,
            footer: "Issued against a completed visit; medication and dosage are as recorded by the attending vet."
        )
    }
}
