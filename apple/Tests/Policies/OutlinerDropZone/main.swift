import Foundation

func placement(from start: CGFloat, to drop: CGFloat, rowX: CGFloat, rowY: CGFloat = 14, depth: Int = 0) -> OutlinerDropPlacement {
    OutlinerDropZone.placement(startX: start, dropX: drop, rowX: rowX, rowY: rowY, rowHeight: 28, depth: depth)
}

precondition(placement(from: 150, to: 150, rowX: 140) == .after, "A vertical drag must remain a sibling")
precondition(placement(from: 150, to: 125, rowX: 115) == .after, "Dragging left must allow outdenting")
precondition(placement(from: 100, to: 121, rowX: 111) == .after)
precondition(placement(from: 100, to: 122, rowX: 112) == .inside)
precondition(placement(from: 45, to: 75, rowX: 65, depth: 2) == .after)
precondition(placement(from: 45, to: 76, rowX: 66, depth: 2) == .inside)
precondition(placement(from: 100, to: 150, rowX: 140, rowY: 1) == .before)
print("Outliner drop policy checks passed")
