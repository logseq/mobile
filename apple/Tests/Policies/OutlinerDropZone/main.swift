import Foundation

// The central, left-hand part of a target row is a sibling drop on mobile.
// Otherwise moving a child out next to its parent almost always nests it again.
precondition(OutlinerDropZone.placement(locationY: 14, rowHeight: 28) == .after,
             "Dropping child 3 onto the middle of parent 2 must allow a sibling move")
precondition(OutlinerDropZone.placement(locationY: 1, rowHeight: 28) == .before)
precondition(OutlinerDropZone.placement(locationY: 27, rowHeight: 28) == .after)
precondition(OutlinerDropZone.placement(locationX: 50, locationY: 14, rowHeight: 28) == .after)
precondition(OutlinerDropZone.placement(locationX: 101, locationY: 14, rowHeight: 28) == .inside)
precondition(OutlinerDropZone.placement(locationX: 101, locationY: 14, rowHeight: 28, depth: 2) == .after)
precondition(OutlinerDropZone.placement(locationX: 145, locationY: 14, rowHeight: 28, depth: 2) == .inside)
precondition(OutlinerDropZone.placement(locationX: 150, locationY: 1, rowHeight: 28) == .before)
print("Outliner drop policy checks passed")
