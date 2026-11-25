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
        print("PASS: journal insertion and the Tasks tab are independent, and the bottom controls fit")
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
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func settle() async throws {
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(450))
            backend.emitFramesSnapshot()
        }
        func press(_ identifier: String) throws {
            guard let id = node(identifier) else { throw failure("Missing " + identifier) }
            try backend.performPress(node: id)
        }
        func checkAgenda(visible: Bool) throws {
            for section in effects.sections {
                guard (node("journal-tasks.\(section)") != nil) == visible else {
                    throw failure("Unexpected visibility for task section " + section)
                }
            }
        }
        func capture(_ name: String) throws {
            guard titles.isEmpty else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(650))
        backend.emitFramesSnapshot()
        try checkAgenda(visible: false)
        let identifiers = ["tab.bottom.home", "tab.bottom.tasks", "tab.bottom.notifications",
                           "button.search", "button.composer.expand"]
        let controls = identifiers.compactMap { node($0).flatMap { frames[$0] } }
        guard controls.count == identifiers.count,
              zip(controls, controls.dropFirst()).allSatisfy({ $0.maxX <= $1.minX }),
              controls.allSatisfy({ $0.width >= 44 && $0.height >= 44 && window.bounds.contains($0) }),
              controls[3].minX - controls[2].maxX > 8 else {
            throw failure("Expected two separate bottom groups with full touch targets: \(controls)")
        }
        try capture("bottom-navigation")
        try press("tab.bottom.tasks")
        try await settle()
        try checkAgenda(visible: true)
        guard let screen = node("list.tasks"), let agenda = frames[screen],
              !agenda.isEmpty, window.bounds.intersects(agenda) else {
            throw failure("The Tasks list must be visible after switching tabs")
        }
        try capture("tasks")
        try press("button.composer.expand")
        try await settle()
        guard editor() != nil else { throw failure("Plus did not focus the composer on Tasks") }
        try capture("composer")
        guard let navigation = backend.rootIDs.flatMap(nodes).first(where: {
            backend.extensionModel(id: $0)?.identifier == "native-navigation-stack"
        }) else { throw failure("Missing native navigation") }
        try backend.performExtensionEvent(node: navigation, name: "dismiss-composer", values: [:])
        try await settle()
        try press("tab.bottom.home")
        try await settle()
        try checkAgenda(visible: false)
        try press("button.outliner.placeholder.today")
        try await settle()
        guard effects.inserts == 1, let field = editor() else { throw failure("Add block did not open an editor") }
        field.insertText("New block")
        try await settle()
        if field.delegate?.textView?(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n") ?? true {
            field.insertText("\n")
        }
        try await settle()
        guard effects.inserts == 2 else { throw failure("Return did not add the next block") }
        try checkAgenda(visible: false)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalTaskInsertion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
