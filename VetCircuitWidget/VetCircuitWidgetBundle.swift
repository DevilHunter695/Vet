import WidgetKit
import SwiftUI

@main
struct VetCircuitWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextVisitWidget()
        // I3: Live Activity/Dynamic Island for "vet en route".
        if #available(iOS 16.1, *) {
            VetEnRouteLiveActivity()
        }
    }
}
