import XCTest

final class OutlinerDropUITests: XCTestCase {
    @MainActor func testDragChangesBlockOrder() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication(bundleIdentifier: try XCTUnwrap(environment["LOGSEQ_DRAG_APP_ID"]))
        app.activate()
        let sourceTitle = try XCTUnwrap(environment["LOGSEQ_DRAG_SOURCE"])
        let targetTitle = try XCTUnwrap(environment["LOGSEQ_DRAG_TARGET"])
        func block(_ title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", title))
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "outliner.block-action.")).firstMatch
        }
        let source = block(sourceTitle)
        let target = block(targetTitle)
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(target.exists)
        let sourceWasAbove = source.frame.midY < target.frame.midY

        // Stay near the leading edge of the target so the drop reorders siblings.
        let destination = target.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: sourceWasAbove ? 0.85 : 0.10))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.5)

        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            source.exists && target.exists && (source.frame.midY < target.frame.midY) != sourceWasAbove
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 8), .completed, "Expected the two blocks to change order")
    }
}
