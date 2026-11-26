import SQLite3
import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@main @MainActor struct OfflineSmokeCheck {
    private static let graphID = "uiregression"

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let graph = directory.appendingPathComponent("graph.sqlite")
        let checkpoint = directory.appendingPathComponent("sync.checkpoint")
        try seedGraph(at: graph)
        try #"["^ ","~:format-version",1,"~:graph-id","uiregression","~:schema-version","65.34","~:applied-server-t",0]"#
            .write(to: checkpoint, atomically: true, encoding: .utf8)

        let catalogPath = directory.appendingPathComponent("logseq.sqlite").path
        let config = [
            "graphId": graphID, "graphName": "iOS smoke graph", "baseUrl": "http://127.0.0.1:1",
            "token": "fixture.eyJzdWIiOiJiZWMwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMTAifQ.fixture",
        ]
        let graphPaths = ["graphId": graphID, "activePath": graph.path, "checkpointPath": checkpoint.path]
        func openGraph() async throws -> String {
            let catalog = LogseqStore.callForLaunch(.init(method: "open", params: .init(action: nil, path: catalogPath)))
            _ = try snapshot(catalog)
            _ = try snapshot(await dispatch("configure", config))
            let response = try await dispatch("openGraph", graphPaths)
            _ = try snapshot(response)
            return response
        }
        let opened = try await openGraph()
        let platform = LGPlatformEffectHandler(saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 20), copyText: { _ in }, signOut: {}, syncPending: {})
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(
            callCore: { await LogseqCore.callAsync($0) },
            platformEffect: { await platform.execute($0) }
        ))
        try runtime.applyCoreResponse(opened)
        try runtime.applyHostUpdate(kind: "local-graph-ids", payload: "[\"\(graphID)\"]")
        try runtime.start(platformCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw failure("No simulator window scene")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }

        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? [])
                .flatMap(descendants)
        }
        func nodes() -> [Int] { backend.rootIDs.flatMap(descendants) }
        func node(_ identifier: String) -> Int? {
            nodes().first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func extensionNode(_ identifier: String) -> Int? {
            nodes().first { backend.extensionModel(id: $0)?.identifier == identifier }
        }
        func press(_ identifier: String) async throws {
            let control = try await waitFor(identifier) { () -> Int? in
                guard let id = node(identifier), backend.model(id: id)?.isEnabled == true else { return nil }
                return id
            }
            try backend.performPress(node: control)
            await runtime.drainEffectsForTesting()
        }
        func focusedInput(in view: UIView) -> (any UIKeyInput)? {
            if view.isFirstResponder, let input = view as? any UIKeyInput { return input }
            return view.subviews.lazy.compactMap(focusedInput).first
        }

        let navigation = try await waitFor("native navigation") { extensionNode("native-navigation-stack") }
        try await press("button.composer.expand")
        let captures = ["Offline smoke capture one", "Offline smoke capture two"]
        for title in captures {
            let field = try await waitFor("focused composer input") { focusedInput(in: window) }
            field.insertText(title)
            await runtime.drainEffectsForTesting()
            try await press("button.send")
            if let error = runtime.lastError { throw failure("Capture failed: \(error)") }
            _ = try await waitFor("submitted capture \(title)") {
                try await currentSnapshot().outlinerRows.first { $0.block.title == title }
            }
            _ = try await waitFor("cleared composer draft") { () -> Bool? in
                guard let send = node("button.send"), backend.model(id: send)?.isEnabled == false,
                      let input = focusedInput(in: window), !input.hasText else { return nil }
                return true
            }
        }
        // Mirror the native dismissal surface, which resigns UIKit focus first.
        window.endEditing(true)
        try backend.performExtensionEvent(node: navigation, name: "dismiss-composer", values: [:])
        await runtime.drainEffectsForTesting()
        _ = try await waitFor("collapsed composer") { node("button.composer.expand") }
        print("PASS: two native composer submissions appear in the journal")

        let before = try await currentSnapshot()
        let firstCapture = try require(before.outlinerRows.first { $0.block.title == captures[0] }?.block,
                                       "The first capture is missing from the journal")
        let row = try await waitFor("captured outliner row") {
            nodes().first { id in
                guard let model = backend.extensionModel(id: id), model.identifier == "outliner-block-row",
                      case let .string(payload) = model.property("payload") else { return false }
                return (try? JSONDecoder().decode(OutlinerRowPayload.self, from: Data(payload.utf8)))?.uuid == firstCapture.uuid
            }
        }
        try backend.performExtensionEvent(node: row, name: "edit", values: [
            "uuid": .string(firstCapture.uuid), "caret-utf16-offset": .int(firstCapture.title.utf16.count),
        ])
        let editor = try await waitFor("native outliner editor") { () -> UITextView? in
            guard let view = focusedInput(in: window) as? UITextView,
                  view.accessibilityIdentifier == "field.outliner.block.\(firstCapture.uuid)" else { return nil }
            return view
        }
        guard editor.delegate?.textView?(editor, shouldChangeTextIn: editor.selectedRange, replacementText: "\n") == false else {
            throw failure("The outliner inserted a newline instead of creating a block")
        }
        var edited = try await waitFor("first new journal block") {
            let current = try await currentSnapshot()
            return current.outlinerRows.count == before.outlinerRows.count + 1 ? current : nil
        }
        for count in 2...3 {
            let block = try require(edited.outlinerState.editing?.uuid, "Return did not move editing to the new block")
            let nextEditor = try await waitFor("new outliner editor") { () -> Int? in
                guard let id = extensionNode("outliner-editor"),
                      case let .string(uuid) = backend.extensionModel(id: id)?.property("block-id"),
                      uuid == block else { return nil }
                return id
            }
            try backend.performExtensionEvent(node: nextEditor, name: "return", values: [
                "title": .string(""), "caret-utf16-offset": .int(0),
            ])
            edited = try await waitFor("journal block \(count)") {
                let current = try await currentSnapshot()
                return current.outlinerRows.count == before.outlinerRows.count + count ? current : nil
            }
        }
        let journalRows = edited.outlinerRows.filter { $0.block.pageId == firstCapture.pageId }
        let titles = journalRows.map(\.block.title)
        guard let captureIndex = titles.firstIndex(of: captures[0]),
              Array(titles.dropFirst(captureIndex + 1).prefix(3)) == ["", "", ""] else {
            throw failure("Consecutive Return presses must preserve the original title and insert three blank blocks")
        }
        print("PASS: consecutive Return presses preserve existing text")

        let editingNode = try await waitFor("editor after three Return presses") { extensionNode("outliner-editor") }
        try backend.performExtensionEvent(node: editingNode, name: "ime-dismissed", values: [:])
        await runtime.drainEffectsForTesting()
        try await press("button.search")
        _ = try await waitFor("search screen") { node("screen.search") }
        let search = try await waitFor("native search") { extensionNode("native-search-presentation") }
        try backend.performExtensionEvent(node: search, name: "query-changed", values: ["query": .string(captures[0])])
        _ = try await waitFor("search result for the capture") { node("search.result.\(firstCapture.uuid)") }
        try backend.performExtensionEvent(node: search, name: "dismiss", values: [:])
        await runtime.drainEffectsForTesting()
        try await press("button.sidebar")
        _ = try await waitFor("sidebar settings") { node("button.sidebar.settings") }
        let sidebar = try await waitFor("sidebar overlay") { extensionNode("sidebar-overlay") }
        try backend.performExtensionEvent(node: sidebar, name: "close", values: [:])
        await runtime.drainEffectsForTesting()
        print("PASS: opens and closes search and the sidebar")

        runtime.stop()
        window.isHidden = true
        window.rootViewController = nil
        let reopened = try snapshot(await openGraph())
        let persisted = reopened.outlinerRows.filter { $0.block.pageId == firstCapture.pageId }.map(\.block)
        guard captures.allSatisfy({ title in persisted.filter { $0.title == title }.count == 1 }),
              persisted.map(\.uuid) == journalRows.map(\.block.uuid),
              persisted.map(\.title) == titles else {
            let allRows = reopened.outlinerRows.map { "\($0.block.pageId):\($0.block.title)" }
            throw failure("Saved rows changed on reopen: expected \(firstCapture.pageId):\(titles), found \(allRows)")
        }
        print("PASS: saved captures and blank blocks survive a graph reopen")
    }

    private static func seedGraph(at url: URL) throws {
        let fixture = try require(Bundle.main.url(forResource: "offline-smoke", withExtension: "sql"), "Missing smoke graph")
        // The fixture is a confirmed journal. Use today's date in the simulator's time zone.
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.calendar = Calendar(identifier: .gregorian)
        date.dateFormat = "yyyyMMdd"
        let today = date.string(from: Date())
        let todayUUID = "00000001-\(today.prefix(4))-\(today.suffix(4))-0000-000000000000"
        let sql = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "20010101", with: today)
            .replacingOccurrences(of: "00000001-2001-0101-0000-000000000000", with: todayUUID)
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK,
              sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure("Could not seed SQLite graph: \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    private static func dispatch(_ action: String, _ fields: [String: String]) async throws -> String {
        let payload = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        return await LogseqCore.callAsync(.init(method: "dispatch", params: .init(action: action, payload: payload)))
    }

    private static func snapshot(_ response: String) throws -> LogseqSnapshot {
        let envelope = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(response.utf8))
        return try require(envelope.result, envelope.error?.message ?? "Missing graph snapshot")
    }

    private static func currentSnapshot() async throws -> LogseqSnapshot {
        try snapshot(await LogseqCore.callAsync(.init(method: "snapshot", params: .init(action: nil))))
    }

    private static func waitFor<T>(_ description: String, _ check: () async throws -> T?) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(4)
        repeat {
            if let result = try await check() { return result }
            try await Task.sleep(for: .milliseconds(30))
        } while clock.now < deadline
        throw failure("Timed out waiting for \(description)")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }
        return value
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OfflineSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
