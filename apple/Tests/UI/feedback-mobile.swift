import Foundation
import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@main struct FeedbackMobileApp: App {
    private let probe = FeedbackMobileProbe()
    var body: some Scene {
        WindowGroup {
            LGRendererRoot(renderer: probe.runtime.renderer)
                .task { await probe.run() }
        }
    }
}

@MainActor final class FeedbackMobileProbe {
    let runtime: LGRuntime
    let router: LGPlatformCommandRouter
    let scenario = ProcessInfo.processInfo.environment["LOGSEQ_FEEDBACK_SCENARIO"] ?? "navigation"
    let directory = URL.documentsDirectory
    var observations: [String: Bool] = [:]
    var measurements: [String: Double] = [:]
    let selectedSnapshot: String
    private var step = 0
    private static let prefix = "f0000000-0000-4000-8000-"
    static func uuid(_ number: Int) -> String { prefix + String(format: "%012d", number) }

    static func call(_ action: String?, _ payload: String? = nil, path: String? = nil) -> String {
        LogseqStore.callForLaunch(LogseqRPCRequest(method: action == nil ? "open" : "dispatch",
            params: LogseqRPCParams(action: action, payload: payload, path: path)))
    }
    static func encoded(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    init() {
        setbuf(stdout, nil)
        UserDefaults.standard.set("feedback", forKey: "logseq.selectedGraphId")
        _ = Self.call(nil, path: directory.appendingPathComponent("logseq.sqlite").path)
        let catalogURL = ProcessInfo.processInfo.environment["LOGSEQ_FEEDBACK_CATALOG_URL"] ?? "http://127.0.0.1:1"
        _ = Self.call("configure", Self.encoded(["graphId":"feedback", "baseUrl":catalogURL,
            "token":scenario == "responsiveness" ? "feedback-test-token" : ""]))
        let graph = directory.appendingPathComponent("graphs/feedback")
        let opened = Self.call("openGraph", Self.encoded(["graphId":"feedback",
            "activePath":graph.appendingPathComponent("graph.sqlite").path,
            "checkpointPath":graph.appendingPathComponent("sync.checkpoint").path,"isEncrypted":false]))
        try? Data(opened.utf8).write(to: directory.appendingPathComponent("feedback-startup.json"))
        precondition(opened.contains("\"ok\":true"), opened)
        let selected: Int
        switch scenario {
        case "code-language", "special-block", "android-controls": selected = 2
        case "attachment-refresh", "image-parent", "image-retry": selected = 3
        case "youtube": selected = 4
        case "math": selected = 5
        case "comments", "reactions": selected = 7
        default: selected = 1
        }
        let response = Self.call("selectPage", Self.uuid(selected))
        selectedSnapshot = response
        router = LGPlatformCommandRouter(setClipboardText: { _ in }, performHaptic: { _ in }, present: { _ in })
        runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(
            platformEffect: { _ in .init(succeeded: true, message: "", output: .discard) }),
            platformCommandHandler: router)
        try! runtime.applyCoreResponse(opened)
        try! runtime.applyCoreResponse(response)
        try! runtime.applyHostUpdate(kind: "local-graph-ids", payload: #"["feedback"]"#)
        try! runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try! runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
    }
    private var backend: LUIAppleBackend { runtime.renderer.backend }
    private func descendants(_ id: Int) -> [Int] {
        [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
    }
    private func find(_ identifier: String) -> Int? {
        backend.rootIDs.flatMap(descendants).first {
            backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
        }
    }
    private func press(_ identifier: String) throws {
        guard let id = find(identifier) else { throw NSError(domain: "Feedback", code: 1,
            userInfo: [NSLocalizedDescriptionKey:"Missing control: " + identifier]) }
        try backend.performPress(node: id)
    }
    private func extensionEvent(_ identifier: String, _ name: String, _ values: [String: LUIExtensionValue]) throws {
        guard let id = backend.rootIDs.flatMap(descendants).first(where: { backend.extensionModel(id: $0)?.identifier == identifier }) else {
            throw NSError(domain: "Feedback", code: 2, userInfo: [NSLocalizedDescriptionKey:"Missing extension: " + identifier])
        }
        runtime.renderer.receiveForTesting(LGRendererEvent(kind: .extension, nodeID: id,
            extensionIdentifier: identifier, extensionName: name, extensionValues: values))
    }
    private func pause() async {
        try? await Task.sleep(for: .seconds(2))
        step += 1
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: \.isKeyWindow) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try? image.pngData()?.write(to: directory.appendingPathComponent("feedback-\(scenario)-\(step).png"))
        }
    }
    func run() async {
        do {
            await pause()
            switch scenario {
            case "language":
                try runtime.applyHostUpdate(kind: "settings", payload: #"{"appearance":"system","language":"system","systemLanguage":"zh-CN","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"http://127.0.0.1:1","version":"QA","revision":"feedback"}"#)
                try press("button.sidebar"); await pause()
                try press("button.sidebar.settings"); await pause()
                if let id = find("sheet.settings") { observations["system-language"] = backend.model(id: id)?.property(.text)?.stringValue == "设置" }
            case "code-language":
                observations["picker"] = find("button.outliner.code-language." + Self.uuid(12)) != nil
                if observations["picker"] == true {
                    try press("button.outliner.code-language.option.python"); await pause()
                }
            case "special-block", "android-controls":
                try extensionEvent("outliner-block-row", "edit", ["uuid": .string(Self.uuid(12))]); await pause()
                observations["continuation"] = find("button.outliner.placeholder." + Self.uuid(2)) != nil
            case "attachment-refresh", "image-parent", "image-retry":
                try extensionEvent("outliner-block-row", "edit", ["uuid": .string(Self.uuid(13))]); await pause()
                try press("button.outliner.editor.camera"); await pause()
                let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { c in
                    UIColor.systemGreen.setFill(); c.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                    ("Captured photo" as NSString).draw(at: CGPoint(x: 60, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white])
                }
                let file = directory.appendingPathComponent("captured.png"); try image.pngData()!.write(to: file)
                let response = Self.call("addAsset", Self.encoded(["uuid":Self.uuid(30),"title":"Captured photo.png",
                    "assetType":"png","assetSize":(try Data(contentsOf: file)).count,"assetChecksum":"feedback-photo",
                    "localPath":file.path,"targetBlockId":Self.uuid(13)]))
                try Data(response.utf8).write(to: directory.appendingPathComponent("feedback-import.json"))
                try runtime.applyCoreResponse(response); await pause()
                observations["import"] = response.contains("\"ok\":true")
                observations["editor-dismissed"] = !backend.rootIDs.flatMap(descendants).contains {
                    backend.extensionModel(id: $0)?.identifier == "outliner-editor"
                }
                let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
                let result = envelope?["result"] as? [String: Any]
                let rows = result?["outlinerRows"] as? [[String: Any]] ?? []
                let imageBlock = rows.first?["block"] as? [String: Any]
                let localPath = imageBlock?["localPath"] as? String ?? ""
                observations["offline-local-preview"] = FileManager.default.fileExists(atPath: localPath)
                let preview = Self.call("prepareAssetDownload", Self.encoded(["uuid":imageBlock?["uuid"] as? String ?? Self.uuid(13), "assetType":"png"]))
                let previewEnvelope = try JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any]
                let previewResult = previewEnvelope?["result"] as? [String: Any]
                observations["no-network-download"] = previewResult?["localPath"] as? String == localPath && previewResult?["request"] == nil
                observations["no-empty-parent"] = rows.count == 1 && (rows.first?["block"] as? [String: Any])?["isAsset"] as? Bool == true
                if find("button.outliner.editor.hideKeyboard") != nil {
                    try press("button.outliner.editor.hideKeyboard"); await pause()
                }
            case "search-tags":
                try press("button.search"); await pause()
                try extensionEvent("native-search-presentation", "query-changed", ["query":.string("#code")]); await pause()
                observations["code-tag"] = backend.rootIDs.flatMap(descendants).contains { backend.model(id: $0)?.property(.text)?.stringValue == "Code" }
            case "search-toolbar":
                try press("button.search"); await pause()
                try extensionEvent("native-search-presentation", "query-changed", ["query":.string("print")]); await pause()
                try press("search.result." + Self.uuid(12)); await pause()
                try extensionEvent("outliner-block-row", "edit", ["uuid":.string(Self.uuid(12))]); await pause()
                observations["editor-toolbar"] = find("toolbar.outliner.editor") != nil
            case "navigation":
                try runtime.applyHostUpdate(kind: "open-node", payload: "\"" + Self.uuid(1) + "\""); await pause()
                try extensionEvent("outliner-block-row", "open-node", ["uuid":.string(Self.uuid(6))]); await pause()
                try runtime.applyHostUpdate(kind: "open-node", payload: "\"" + Self.uuid(1) + "\""); await pause()
            case "responsiveness":
                _ = Self.call("configure", Self.encoded(["graphId":"",
                    "baseUrl":ProcessInfo.processInfo.environment["LOGSEQ_FEEDBACK_CATALOG_URL"]!, "token":"feedback-test-token"]))
                let executor = LGCoreEffectExecutor()
                Task { _ = await executor.execute(LGEffect(id: 99999, kind: "refresh-graphs", text: "")) }
                try await Task.sleep(for: .milliseconds(300))
                let started = ProcessInfo.processInfo.systemUptime
                try press("button.sidebar")
                while find("button.sidebar.settings") == nil && ProcessInfo.processInfo.systemUptime - started < 8 {
                    try await Task.sleep(for: .milliseconds(40))
                }
                try press("button.sidebar.settings")
                while find("sheet.settings") == nil && ProcessInfo.processInfo.systemUptime - started < 10 {
                    try await Task.sleep(for: .milliseconds(40))
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                measurements["settings-open-ms"] = elapsed * 1000
                observations["controls-responsive"] = find("sheet.settings") != nil && elapsed < 2
                await pause()
            case "youtube":
                let envelope = try JSONSerialization.jsonObject(with: Data(selectedSnapshot.utf8)) as? [String: Any]
                let rows = (envelope?["result"] as? [String: Any])?["outlinerRows"] as? [[String: Any]] ?? []
                observations["embedded-video"] = rows.contains { row in
                    let markup = (row["block"] as? [String: Any])?["markup"] as? [[String: Any]] ?? []
                    return markup.contains { $0["type"] as? String == "video" }
                }
            case "comments": observations["comment-panel"] = find("outliner.comment." + Self.uuid(19)) != nil
            case "reactions": observations["reaction"] = backend.rootIDs.flatMap(descendants).contains { backend.model(id: $0)?.property(.text)?.stringValue == "👍 1" }
            default: break
            }
            await pause()
            let result: [String:Any] = ["scenario":scenario,"observations":observations,"measurements":measurements,"error":runtime.lastError ?? ""]
            try JSONSerialization.data(withJSONObject: result, options:.prettyPrinted).write(to: directory.appendingPathComponent("feedback-result.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject:["scenario":scenario,"failure":String(describing:error)]).write(to: directory.appendingPathComponent("feedback-result.json"))
        }
    }
}
