import Foundation

/// N6: the widget extension's copy of the shared-data contract. This is a
/// separate compile target from the main app (XcodeGen `app-extension`
/// target `VetCircuitWidgetExtension`), so it can't import the main app's
/// `WidgetDataBridge.swift` directly without a third shared-framework
/// target — which is more machinery than this feature needs. Instead this
/// file mirrors the read side of
/// `VetCircuit/Data/WidgetData/WidgetDataBridge.swift` exactly (same struct
/// shape, same App Group suite name, same UserDefaults key) so it can decode
/// what the main app wrote. **Known follow-up**: if either copy's `Codable`
/// shape changes, the other must be updated by hand — a shared framework
/// target would remove that risk but was judged out of scope for this pass.
struct SharedVisitSummary: Codable, Equatable {
    enum Kind: String, Codable {
        case upcomingVisit
        case vaccinationDue
        case none
    }

    var kind: Kind
    var petName: String?
    var vetName: String?
    var date: Date?
    var subtitle: String?
    var vaccineName: String?
    var generatedAt: Date
    /// Optional so decoding stays backward-compatible with data the main app
    /// wrote before this field existed (missing key decodes to `nil` for an
    /// `Optional`, unlike a non-optional field which would fail the whole
    /// decode). Used to build the widget's tap target
    /// (`vetcircuit://visit/<uuid>`, see `DeepLinkParser`); until the main
    /// app's `WidgetDataBridge` write side is updated to populate it, the
    /// widget falls back to opening the app without a specific route.
    var visitId: UUID? = nil

    static let empty = SharedVisitSummary(kind: .none, petName: nil, vetName: nil, date: nil, subtitle: nil, vaccineName: nil, generatedAt: .now, visitId: nil)
}
