import SwiftUI
import UIKit
@testable import Logseq

@main struct AdaptiveContentInsetsCheck {
    @MainActor static func main() async throws {
        var measuredWidth: CGFloat = -1
        let probe = AnyView(GeometryReader { geometry in
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                measuredWidth = $0
            }
        })
        func root(_ width: CGFloat) -> some View {
            LGAdaptiveContentInsets(content: probe, breakpoint: 600, wideInset: 16)
                .frame(width: width, height: 320)
        }
        let host = UIHostingController(rootView: AnyView(root(393)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for (width, expected) in [(393.0,393.0), (599,599), (600,568), (820,788), (1180,1148), (500,500)] {
            host.rootView = AnyView(root(width))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            precondition(abs(measuredWidth - expected) < 0.5,
                         "Reading width \(width): expected \(expected), got \(measuredWidth)")
            print("PASS: available width \(width), content width \(measuredWidth)")
        }
    }
}
