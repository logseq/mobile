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
        startX: CGFloat,
        dropX: CGFloat,
        rowX: CGFloat,
        rowY: CGFloat,
        rowHeight: CGFloat,
        depth: Int = 0
    ) -> OutlinerDropPlacement {
        let topZone = min(16, max(rowHeight, 1) * 0.25)
        if rowY < topZone { return .before }
        let indent: CGFloat = 22
        let childX = CGFloat(max(0, depth) + 1) * indent
        if dropX - startX >= indent && rowX >= childX { return .inside }
        return .after
    }
}
