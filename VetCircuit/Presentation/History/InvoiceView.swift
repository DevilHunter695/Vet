import SwiftUI
import PDFKit

/// G5: renders a GST-compliant invoice PDF for a completed visit, entirely
/// on-device from the already-fetched `Invoice` row — invoice *numbering*
/// and the GST amount are computed and persisted server-side (this only
/// lays the already-issued numbers out as a document), matching the rest of
/// this app's "never compute money client-side" discipline. No gateway/PDF
/// service is needed for this: `UIGraphicsPDFRenderer` is a system framework.
enum InvoicePDFRenderer {
    static func render(_ invoice: Invoice, visit: Visit) -> Data {
        let pageWidth = 595.2, pageHeight = 841.8 // A4 in points
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        return renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 40

            func draw(_ text: String, font: UIFont = .systemFont(ofSize: 12), color: UIColor = .black, x: CGFloat = 40) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
                y += font.lineHeight + 6
            }

            draw("VetCircuit", font: .boldSystemFont(ofSize: 20))
            draw("Tax invoice", font: .systemFont(ofSize: 14), color: .darkGray)
            y += 10
            draw("Invoice number: \(invoice.invoiceNumber)")
            draw("Issued: \(invoice.issuedAt.formatted(date: .long, time: .omitted))")
            draw("Visit date: \(visit.scheduledAt.formatted(date: .long, time: .shortened))")
            y += 10

            draw("Description", font: .boldSystemFont(ofSize: 12), x: 40)
            let amountX: CGFloat = 460
            let headerY = y - (UIFont.boldSystemFont(ofSize: 12).lineHeight + 6)
            ("Amount" as NSString).draw(at: CGPoint(x: amountX, y: headerY), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 12)])
            y += 4

            for item in invoice.breakdown.lineItems {
                let lineY = y
                draw(item.label, x: 40)
                let amountText = CurrencyFormatter.rupees(item.amountMinorUnits)
                (amountText as NSString).draw(at: CGPoint(x: amountX, y: lineY), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            }

            y += 10
            let gstLineY = y
            draw("GST", x: 40)
            (CurrencyFormatter.rupees(invoice.gstMinorUnits) as NSString).draw(at: CGPoint(x: amountX, y: gstLineY), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])

            y += 6
            let totalLineY = y
            draw("Total", font: .boldSystemFont(ofSize: 14), x: 40)
            let totalText = CurrencyFormatter.rupees(invoice.breakdown.totalMinorUnits + invoice.gstMinorUnits)
            (totalText as NSString).draw(at: CGPoint(x: amountX, y: totalLineY), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14)])
        }
    }
}

@Observable
@MainActor
final class InvoiceViewModel {
    var invoice: Invoice?
    var pdfDocument: PDFDocument?
    var errorMessage: String?
    var shareURL: URL?

    private let invoiceRepository = DependencyContainer.shared.invoiceRepository

    func load(visit: Visit) async {
        do {
            guard let invoice = try await invoiceRepository.invoice(visitId: visit.id) else {
                errorMessage = "Your invoice isn't ready yet — it's generated once the visit is finalized."
                return
            }
            self.invoice = invoice
            let data = InvoicePDFRenderer.render(invoice, visit: visit)
            pdfDocument = PDFDocument(data: data)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(invoice.invoiceNumber).pdf")
            try data.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct InvoiceView: View {
    let visit: Visit
    @State private var viewModel = InvoiceViewModel()

    var body: some View {
        Group {
            if let pdfDocument = viewModel.pdfDocument {
                PDFKitView(document: pdfDocument)
            } else if let errorMessage = viewModel.errorMessage {
                EmptyStateView(systemImage: "doc.text", title: "Invoice unavailable", message: errorMessage)
            } else {
                ProgressView()
            }
        }
        .auroraScreenBackground()
        .navigationTitle("Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let shareURL = viewModel.shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await viewModel.load(visit: visit) }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}
