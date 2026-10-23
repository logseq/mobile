import SwiftUI

/// One path per row keeps ancestor guides continuous across virtualized rows.
enum OutlinerGuideGeometry {
    static func path(depth: Int, expanded: Bool, size: CGSize) -> CGPath {
        let path = CGMutablePath()
        for level in 0..<max(0, depth) {
            let x = OutlinerLayoutMetrics.guideCenterX(level: level)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        if expanded, size.height > 17.5 {
            let x = OutlinerLayoutMetrics.bulletCenterX(depth: max(0, depth))
            path.move(to: CGPoint(x: x, y: 17.5))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        return path
    }
}

#if os(iOS)
import UIKit

struct OutlinerIndentGuides: UIViewRepresentable {
    let identifier: String
    let depth: Int
    let expanded: Bool
    init(row: OutlinerRowPayload) {
        identifier = row.uuid
        depth = max(0, row.depth)
        expanded = row.hasChildren && !row.collapsed
    }
    init(identifier: String, guideCount: Int) {
        self.identifier = identifier
        depth = max(0, guideCount)
        expanded = false
    }
    func makeUIView(context: Context) -> OutlinerIndentGuideView { OutlinerIndentGuideView() }
    func updateUIView(_ view: OutlinerIndentGuideView, context: Context) { view.update(identifier: identifier, depth: depth, expanded: expanded) }
}

@MainActor final class OutlinerIndentGuideView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    private var depth = 0
    private var expanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        (layer as? CAShapeLayer)?.fillColor = nil
        (layer as? CAShapeLayer)?.lineWidth = 1
        updateColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: OutlinerIndentGuideView, _: UITraitCollection) in view.updateColor()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ row: OutlinerRowPayload) {
        update(identifier: row.uuid, depth: max(0, row.depth), expanded: row.hasChildren && !row.collapsed)
    }
    func update(identifier: String, depth: Int, expanded: Bool) {
        accessibilityIdentifier = "outliner.indent-guides." + identifier
        self.depth = depth
        self.expanded = expanded
        isHidden = depth == 0 && !expanded
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        (layer as? CAShapeLayer)?.path = OutlinerGuideGeometry.path(depth: depth, expanded: expanded, size: bounds.size)
    }
    private func updateColor() {
        (layer as? CAShapeLayer)?.strokeColor = UIColor.secondaryLabel
            .resolvedColor(with: traitCollection).withAlphaComponent(0.18).cgColor
    }
}
#else
struct OutlinerIndentGuides: View {
    let row: OutlinerRowPayload
    var body: some View {
        Canvas { context, size in
            context.stroke(Path(OutlinerGuideGeometry.path(depth: row.depth,
                expanded: row.hasChildren && !row.collapsed, size: size)),
                with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
