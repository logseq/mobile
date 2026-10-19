import UIKit
import SwiftUI
import LUIAppleBackend

@MainActor final class Titles {
    var current: String?
    var changes = 0
}

@main struct ScrollTitleCheck {
    @MainActor static func main() throws {
        let backend = LUIAppleBackend()
        var ops: [[String: Any]] = [
            ["op": "create-node", "id": 1, "kind": "virtual-list"],
            ["op": "set-prop", "id": 1, "property": "style-class", "value": "scroll-section-titles"],
            ["op": "set-prop", "id": 1, "property": "selected", "value": true]]
        for index in 0..<4 {
            let row = 10 + index * 10
            ops += [["op":"create-node", "id":row, "kind":"column"],
                    ["op":"set-prop", "id":row, "property":"height", "value":180],
                    ["op":"insert-child", "parent":1, "child":row, "index":index]]
            let label = row + 1
            ops += [["op":"create-node", "id":label, "kind":"text"],
                    ["op":"set-prop", "id":label, "property":"text", "value": index < 2 ? "Sep 7th" : "Sep 6th"],
                    ["op":"insert-child", "parent":row, "child":label, "index":0]]
            if index % 2 == 0 { ops += [["op":"set-prop", "id":label, "property":"style-class", "value":"scroll-section-title"]] }
        }
        try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: ["generation":1,"ops":ops]), as: UTF8.self))
        let titles = Titles()
        let host = UIHostingController(rootView: AnyView(
            LUISwiftUIRoot(backend: backend, rootID: 1)
                .frame(width: 300, height: 200)
                .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in
                    titles.current = title; titles.changes += 1
                }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host; window.makeKeyAndVisible()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)); window.rootViewController?.view.layoutIfNeeded() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        settle()
        let scroll = descendants(host.view).compactMap { $0 as? UIScrollView }.first!
        var failures = 0
        func check(_ expected: String?, _ label: String) {
            if titles.current != expected { print("FAIL: \(label) expected=\(String(describing: expected)) actual=\(String(describing: titles.current))"); failures += 1 }
        }
        check("Sep 7th", "initial section")
        let initialChanges = titles.changes
        scroll.setContentOffset(CGPoint(x: 0, y: 230), animated: false); settle()
        check("Sep 7th", "rows below the first header keep their section title")
        if titles.changes != initialChanges { print("FAIL: scrolling inside a section must not republish its title"); failures += 1 }
        scroll.setContentOffset(CGPoint(x: 0, y: 365), animated: false); settle()
        check("Sep 6th", "next section")
        scroll.setContentOffset(.zero, animated: false); settle()
        check("Sep 7th", "scrolling back")
        try backend.apply(json: #"{"generation":2,"ops":[{"op":"set-prop","id":1,"property":"selected","value":false}]}"#)
        settle(); check(nil, "hidden pane clears its title")
        let windowBackend = LUIAppleBackend()
        let metadata = "data-virtual-count\u{1f}160\u{1e}data-virtual-start\u{1f}64\u{1e}data-item-extent\u{1f}32\u{1e}data-section-title-0\u{1f}Sep 7th\u{1e}data-section-title-80\u{1f}Sep 6th"
        var windowOps: [[String: Any]] = [
            ["op":"create-node", "id":1, "kind":"virtual-list"],
            ["op":"set-prop", "id":1, "property":"style-class", "value":"scroll-section-titles"],
            ["op":"set-prop", "id":1, "property":"selected", "value":true],
            ["op":"create-node", "id":2, "kind":"list"],
            ["op":"set-prop", "id":2, "property":"data-attrs", "value":metadata],
            ["op":"insert-child", "parent":1, "child":2, "index":0]]
        for index in 64..<96 {
            let id = index + 100
            windowOps += [["op":"create-node", "id":id, "kind":"text"],
                ["op":"set-prop", "id":id, "property":"height", "value":40],
                ["op":"set-prop", "id":id, "property":"text", "value":"Block \(index)"],
                ["op":"insert-child", "parent":2, "child":id, "index":index - 64]]
        }
        try windowBackend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: ["generation":1,"ops":windowOps]), as: UTF8.self))
        titles.current = nil
        let windowHost = UIHostingController(rootView: AnyView(LUISwiftUIRoot(backend: windowBackend, rootID: 1)
            .frame(width: 300, height: 200)
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in titles.current = title; titles.changes += 1 }))
        window.rootViewController = windowHost
        settle()
        var generation = 1
        var virtualMetadata = metadata
        func reveal(_ index: Int) throws {
            generation += 1
            let requested = virtualMetadata + "\u{1e}data-scroll-key\u{1f}check-\(generation)\u{1e}data-scroll-index\u{1f}\(index)"
            try windowBackend.apply(json: String(decoding: JSONSerialization.data(withJSONObject:
                ["generation":generation,"ops":[["op":"set-prop", "id":2, "property":"data-attrs", "value":requested]]]), as: UTF8.self))
            settle()
        }
        try reveal(65)
        check("Sep 7th", "window rows retain their date after the header is unmounted")
        try reveal(85)
        check("Sep 6th", "crossing a virtual section updates the title")
        try reveal(20)
        check("Sep 7th", "unmounted rows retain section titles when scrolling back")
        virtualMetadata = metadata.replacingOccurrences(of: "data-virtual-start\u{1f}64", with: "data-virtual-start\u{1f}96")
        try reveal(105)
        check("Sep 6th", "replacing the mounted window preserves its journal title")
        try reveal(0)
        check("Sep 7th", "scrolling back across an evicted window restores the earlier title")
        guard failures == 0 else { exit(1) }
        print("PASS: section title follows scrolling, stays stable within a section, and clears when hidden")
    }
}
