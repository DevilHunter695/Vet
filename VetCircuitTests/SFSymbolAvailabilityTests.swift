import Testing
import UIKit
@testable import VetCircuit

/// Every SF Symbol the app asks for, checked against the SDK it builds on.
///
/// `Image(systemName:)` with a name that does not exist renders as blank
/// space. It does not warn, it does not crash, and it is invisible in code
/// review — so a mistyped or too-new symbol ships as a hole in the layout and
/// is usually found by a user rather than by us. An audit of these names could
/// only reach "probably fine" by recall; this reaches an answer.
///
/// Anything introduced after the deployment target fails here too, because
/// `UIImage(systemName:)` resolves against the running OS. That is the point:
/// a symbol added in a later SF Symbols release is exactly the case recall is
/// worst at.
///
/// The list is generated from the source with:
/// `grep -rhoE '(systemName|systemImage): *"[^"]+"' VetCircuit/ VetCircuitWidget/ --include=*.swift`
/// Add a symbol here when you add one to the app.
@MainActor
struct SFSymbolAvailabilityTests {
    static let symbolsUsedInTheApp: [String] = [
        "archivebox",
        "arrow.clockwise.circle.fill",
        "arrow.down.circle",
        "arrow.up",
        "arrow.up.arrow.down",
        "arrow.up.circle",
        "arrow.uturn.forward.circle.fill",
        "bell",
        "bell.badge",
        "bell.badge.fill",
        "bolt.fill",
        "bubble.left.and.bubble.right",
        "bubble.left.and.text.bubble.right",
        "bubble.left.fill",
        "building.2.fill",
        "calendar",
        "calendar.badge.clock",
        "calendar.badge.exclamationmark",
        "calendar.badge.plus",
        "camera.fill",
        "cart",
        "cart.fill",
        "checklist",
        "checkmark",
        "checkmark.circle.fill",
        "checkmark.seal.fill",
        "chevron.left",
        "chevron.right",
        "clock",
        "clock.arrow.circlepath",
        "clock.badge.exclamationmark",
        "clock.fill",
        "creditcard",
        "creditcard.fill",
        "cross.vial",
        "cross.vial.fill",
        "crown.fill",
        "doc.plaintext",
        "doc.richtext",
        "doc.text",
        "doc.text.fill",
        "doc.text.image",
        "exclamationmark.bubble.fill",
        "exclamationmark.circle.fill",
        "exclamationmark.shield.fill",
        "exclamationmark.triangle",
        "exclamationmark.triangle.fill",
        "faceid",
        "figure.walk.motion",
        "flame.fill",
        "gift",
        "globe",
        "hand.raised",
        "hand.raised.fill",
        "hand.wave.fill",
        "heart.fill",
        "heart.slash",
        "heart.text.square",
        "indianrupeesign.circle",
        "indianrupeesign.circle.fill",
        "info.circle.fill",
        "lifepreserver",
        "lightbulb.fill",
        "link",
        "list.bullet.clipboard",
        "list.bullet.rectangle",
        "location.fill",
        "lock.badge.clock.fill",
        "lock.fill",
        "lock.shield",
        "lock.trianglebadge.exclamationmark",
        "map",
        "map.fill",
        "mappin",
        "mappin.and.ellipse",
        "message.fill",
        "note.text",
        "pause.circle",
        "pawprint.circle.fill",
        "pawprint.fill",
        "person.2",
        "person.3",
        "person.crop.circle",
        "person.fill",
        "person.text.rectangle",
        "phone.fill",
        "photo.badge.exclamationmark",
        "pills.fill",
        "play.circle",
        "plus",
        "plus.circle",
        "plus.circle.fill",
        "questionmark.circle",
        "rectangle.portrait.and.arrow.right",
        "repeat",
        "scalemass",
        "scalemass.fill",
        "shield.lefthalf.filled",
        "shippingbox",
        "slider.horizontal.3",
        "sparkles",
        "square.and.arrow.up",
        "square.and.arrow.up.on.square",
        "square.stack",
        "star",
        "star.circle.fill",
        "star.fill",
        "stethoscope",
        "syringe",
        "syringe.fill",
        "thermometer.medium",
        "trash",
        "tray",
        "tray.full",
        "wallet.pass",
        "wifi.exclamationmark",
        "wifi.slash",
        "xmark",
        "xmark.circle",
        "xmark.circle.fill",
        "xmark.seal.fill"
    ]

    @Test("every SF Symbol the app draws actually exists")
    func allSymbolsResolve() {
        var missing: [String] = []
        for name in Self.symbolsUsedInTheApp where UIImage(systemName: name) == nil {
            missing.append(name)
        }
        #expect(missing.isEmpty,
                "These SF Symbols do not resolve and will render as blank space: \(missing.joined(separator: ", "))")
    }
}
