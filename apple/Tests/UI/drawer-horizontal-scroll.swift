import UIKit
@testable import LUIAppleBackend

@main struct DrawerHorizontalScrollCheck {
    @MainActor static func main() {
        let vertical = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        vertical.contentSize = CGSize(width: 320, height: 1200)
        let table = UIScrollView(frame: CGRect(x: 0, y: 100, width: 320, height: 200))
        table.contentSize = CGSize(width: 1200, height: 200)
        let cell = UILabel(frame: CGRect(x: 0, y: 0, width: 170, height: 44))
        table.addSubview(cell)
        vertical.addSubview(table)
        precondition(LUIDrawerScrollInteractionPolicy.defersToHorizontalScroll(from: cell),
                     "A right swipe in a wide table belongs to its horizontal scroll view")
        precondition(!LUIDrawerScrollInteractionPolicy.defersToHorizontalScroll(from: vertical),
                     "Ordinary vertical content retains the sidebar swipe")
        table.isScrollEnabled = false
        precondition(!LUIDrawerScrollInteractionPolicy.defersToHorizontalScroll(from: cell),
                     "A disabled horizontal scroller does not intercept sidebar gestures")
        print("PASS: table scroll wins without disabling sidebar gestures in ordinary content")
    }
}
