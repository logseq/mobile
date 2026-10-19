import Foundation

enum OutlinerDropPlacement: Equatable {
    case before
    case inside
    case after

    var eventValue: String {
        switch self {
        case .before: return "before"
        case .inside: return "inside"
        case .after: return "after"
        }
    }
}

enum OutlinerDropZone {
    static func placement(
        locationX: CGFloat = 0,
        locationY: CGFloat,
        rowHeight: CGFloat,
        depth: Int = 0
    ) -> OutlinerDropPlacement {
        let topZone = min(16, max(rowHeight, 1) * 0.25)
        if locationY < topZone { return .before }
        if locationX > CGFloat(max(0, depth)) * 22 + 100 { return .inside }
        return .after
    }
}
