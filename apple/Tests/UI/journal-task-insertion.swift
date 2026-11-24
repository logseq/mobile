import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class JournalInsertionEffects: LGEffectExecuting {
    let sections = ["overdue", "doing", "planned"]
    var titles: [String]
    var editing = false
    var inserts = 0

    init(titles: [String]) { self.titles = titles }

    func snapshot(replacing previousCount: Int? = nil) throws -> String {
        func row(_ uuid: String, _ title: String, _ day: Int, _ page: String) -> [String: Any] {
            ["depth": 0, "block": ["uuid": uuid, "title": title, "pageId": page,
                                  "journalDay": day, "journalTitle": page]]
        }
        var agenda: [String: Any] = ["graphId": "demo", "page": "today", "day": 20261124,
                                        "enabled": true, "success": true]
        for section in sections {
            let block = ["uuid": "task-\(section)", "title": "Task \(section)", "pageId": "source"]
            agenda[section] = [["uuid": "task-\(section)", "block": block]]
        }
        let rows = titles.enumerated().map { row("block-\($0.offset)", $0.element, 20261124, "today") }
        var result: [String: Any] = [
            "selectedGraphId": "demo", "graphName": "Journal test",
            "outlinerRows": rows + [row("older", "Previous block", 20261123, "previous")],
            "emptyJournals": rows.isEmpty ? [["uuid": "today", "title": "today", "journalDay": 20261124]] : [],
            "journalTasks": agenda,
            "outlinerState": editing ? ["editing": ["uuid": "block-\(titles.count - 1)",
                                                     "title": titles.last ?? "", "caretUTF16Offset": titles.last?.utf16.count ?? 0]] : [:],
        ]
        if let previousCount {
            result.removeValue(forKey: "outlinerRows")
            result["isOutlinerPatch"] = true
            result["outlinerRowSplices"] = [["start": 0, "deleteCount": previousCount, "rows": rows]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        let previousCount = titles.count
        switch effect.kind {
        case "add-root-block", "return-outliner-editor":
            inserts += 1
            titles.append("")
            editing = true
        case "change-outliner-text":
            titles[titles.count - 1] = effect.text
        default:
            return .init(succeeded: true, message: "", output: .discard)
        }
        return .init(succeeded: true, message: try! snapshot(replacing: previousCount))
    }
}

@main struct JournalTaskInsertionCheck {
    @MainActor static func main() async throws {
        for titles in [[], ["Existing block"]] {
            try await check(titles)
        }
        print("PASS: creating a block moves the agenda by one row and typing keeps it in place")
    }

    @MainActor static func check(_ titles: [String]) async throws {
        let effects = JournalInsertionEffects(titles: titles)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        let backend = runtime.renderer.backend
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        func node(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(nodes).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func editor() -> UITextView? {
            views(window).compactMap { $0 as? UITextView }.first(where: \.isFirstResponder)
        }
        var samples: [[CGFloat]] = []
        var headingIDs: [Int] = []
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames in
            let positions = headingIDs.compactMap { frames[$0]?.minY }
            if positions.count == 3 { samples.append(positions) }
        }
        try await Task.sleep(for: .milliseconds(650))
        headingIDs = effects.sections.compactMap { node("journal-tasks.\($0)") }
        guard headingIDs.count == 3, let placeholder = node("button.outliner.placeholder.today") else {
            throw failure("Missing journal headings or placeholder")
        }
        func measure(_ title: String, movement: CGFloat, _ change: () throws -> Void) async throws {
            samples.removeAll()
            backend.emitFramesSnapshot()
            try change()
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(450))
            backend.emitFramesSnapshot()
            var changes: [[CGFloat]] = []
            for sample in samples where changes.last != sample { changes.append(sample) }
            guard let before = changes.first, let after = changes.last else {
                throw failure("The task headings must stay visible while testing \(title)")
            }
            for (index, start) in before.enumerated() {
                let destination = start + movement
                guard abs(after[index] - destination) <= 1,
                      changes.allSatisfy({ (start - 1...destination + 1).contains($0[index]) }) else {
                    throw failure("Task headings moved unexpectedly while testing \(title) with \(titles.count) existing rows: \(changes)")
                }
            }
        }
        try await measure("Add block", movement: 28) { try backend.performPress(node: placeholder) }
        guard effects.inserts == 1, let field = editor() else { throw failure("Add block did not open an editor") }
        try await measure("Type", movement: 0) { field.insertText("New block") }
        try await measure("Return", movement: 28) {
            if field.delegate?.textView?(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n") ?? true {
                field.insertText("\n")
            }
        }
        guard effects.inserts == 2 else { throw failure("Return did not add the next block") }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalTaskInsertion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
