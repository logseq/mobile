import Foundation
import Darwin
import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend
import LogseqModel

@MainActor final class FrameBenchmark: NSObject {
    static let shared = FrameBenchmark()
    private var link: CADisplayLink?
    private var last = 0.0
    private var gaps: [Double] = []
    private var label: String?
    func begin(_ label: String) {
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        self.label = label
        gaps = []
        last = ProcessInfo.processInfo.systemUptime
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if label != nil { gaps.append((now-last)*1000) }
        last = now
    }
    func finish() {
        guard let label else { return }
        let sorted = gaps.sorted()
        let missed = gaps.reduce(0) { $0 + max(0, Int(($1 / (1000.0 / 60)).rounded()) - 1) }
        let fps = gaps.isEmpty ? 0 : Double(gaps.count) * 1000 / gaps.reduce(0, +)
        print("FRAME_RATE label=\(label) fps=\(fps) missed_frames=\(missed)")
        print("FRAME_BENCH label=\(label) frames=\(gaps.count) max_ms=\(sorted.last ?? 0) p95_ms=\(sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))])")
        if label == "select-0", let limit = ProcessInfo.processInfo.environment["LOGSEQ_BENCH_MAX_FRAME_MS"].flatMap(Double.init) {
            precondition((sorted.last ?? 0) <= limit, "Opening a page exceeded the configured main-thread frame budget")
        }
        self.label = nil
    }
}

private let benchmarkPageUUID = ProcessInfo.processInfo.environment["LOGSEQ_BENCH_PAGE_UUID"] ?? "6954ee2a-506b-4dd9-bd6d-0dc24db9c055"

@main struct UIRegressionApp: App {
    private let runtime: LGRuntime

    @MainActor init() {
        setbuf(stdout, nil)
        let documents = URL.documentsDirectory
        func call(_ action: String?, _ payload: String? = nil, path: String? = nil) -> String {
            LogseqStore.callForLaunch(LogseqRPCRequest(
                method: action == nil ? "open" : "dispatch",
                params: LogseqRPCParams(action: action, payload: payload, path: path)))
        }
        _ = call(nil, path: documents.appendingPathComponent("logseq.sqlite").path)
        _ = call("configure", #"{"graphId":"uiregression","baseUrl":"http://127.0.0.1:1","token":""}"#)
        let graph = documents.appendingPathComponent("graphs/uiregression")
        let data: [String: Any] = ["graphId": "uiregression", "activePath": graph.appendingPathComponent("graph.sqlite").path,
                                  "checkpointPath": graph.appendingPathComponent("sync.checkpoint").path, "isEncrypted": false]
        let payload = String(decoding: try! JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        let opened = call("openGraph", payload)
        print("BENCH_GRAPH_OPEN_OK=\(opened.contains("\"ok\":true"))")
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(
            callCore: { request in
                let started = ProcessInfo.processInfo.systemUptime
                print("BENCH_RPC begin action=\(request.params.action ?? "none")")
                let response = await LogseqCore.callAsync(request)
                print("BENCH_RPC end action=\(request.params.action ?? "none") ms=\((ProcessInfo.processInfo.systemUptime - started)*1000) bytes=\(response.utf8.count)")
                return response
            },
            platformEffect: { _ in LGEffectResolution(succeeded: true, message: "", output: .discard) }))
        try! runtime.applyCoreResponse(opened)
        try! runtime.applyCoreResponse(call("loadSidebar"))
        let page = ProcessInfo.processInfo.environment["LOGSEQ_UI_PAGE_KIND"] == "tag" ? "e2e30000-0000-4000-8000-000000000005" : benchmarkPageUUID
        if ProcessInfo.processInfo.environment["LOGSEQ_BENCH_FIRST_OPEN"] != "1" {
            let selected = call("selectPage", page)
            print("BENCH_SELECTION_OK=\(selected.contains("\"ok\":true"))")
            try! runtime.applyCoreResponse(selected)
        }
        try! runtime.applyHostUpdate(kind: "local-graph-ids", payload: #"["uiregression"]"#)
        try! runtime.start(platformCode: 2, authenticationCode: 3)
        let deliver = runtime.renderer.onEvent
        runtime.renderer.onEvent = { event in
            let started = ProcessInfo.processInfo.systemUptime
            print("SIDEBAR_EVENT begin kind=\(event.kind) node=\(event.nodeID) t=\(started)")
            deliver?(event)
            print("SIDEBAR_EVENT return ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
        }
        self.runtime = runtime
    }

    var body: some Scene {
        WindowGroup {
            LGRendererRoot(renderer: runtime.renderer).task {
                let backend = runtime.renderer.backend
                try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["LOGSEQ_BENCH_START_DELAY"] ?? "2") ?? 2))
                var extensionID: Int?
                @MainActor func report(_ phase: String) {
                    print("BENCH_RUNTIME phase=\(phase) error=\(runtime.lastError ?? "none")")
                    var pending = backend.rootIDs
                    var collections: [Int] = []
                    var containers = 0
                    var plain = 0
                    var nativePlain = 0
                    var nativeRich = 0
                    var surfaceSamples: Set<String> = []
                    while let id = pending.popLast() {
                        if let model = backend.model(id: id) {
                            if [.row, .column, .box].contains(model.kind) {
                                containers += 1
                                if LUIPlainContainerSurfacePolicy.applies(kind: model.kind, properties: model.properties, styleClass: model.derived.styleClass) { plain += 1 }
                                let keys: [LUIProperty] = [.background, .foreground, .borderWidth, .cornerRadius, .opacity, .margin, .tooltip, .minHeight, .maxHeight]
                                surfaceSamples.insert(keys.compactMap { key in model.property(key).map { "\(key.rawValue)=\($0)" } }.joined(separator: ","))
                            }
                            if model.property(.accessibilityIdentifier)?.stringValue == "list.outliner" {
                                collections.append(id)
                            }
                            pending.append(contentsOf: model.children)
                        } else if let model = backend.extensionModel(id: id) {
                            if model.identifier == "outliner-block-row" {
                                extensionID = id
                                guard case let .string(encoded) = model.property("payload") else {
                                    preconditionFailure("Native row payload is missing")
                                }
                                do {
                                    let row = try JSONDecoder().decode(OutlinerRowPayload.self, from: Data(encoded.utf8))
                                    precondition(!row.uuid.isEmpty, "A rendered row must have an identity")
                                    if !row.isAsset && row.markup.allSatisfy({ $0.type == .text }) { nativePlain += 1 }
                                    else { nativeRich += 1 }
                                } catch { preconditionFailure("Native row payload cannot render: \(error)") }
                            }
                            pending.append(contentsOf: model.children)
                        }
                    }
                    func textRows(_ view: UIView) -> [OutlinerTextRowView] {
                        ((view as? OutlinerTextRowView).map { [$0] } ?? []) + view.subviews.flatMap(textRows)
                    }
                    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
                    let rendered = windows.flatMap(textRows)
                    if nativePlain > 0 { precondition(!rendered.isEmpty, "Native text rows must actually be visible in the UI hierarchy") }
                    print("NATIVE_ROW_VIEWS phase=\(phase) count=\(rendered.count)")
                    print("ROW_RENDERERS phase=\(phase) plain=\(nativePlain) rich=\(nativeRich)")
                    print("SURFACE_BENCH phase=\(phase) containers=\(containers) plain=\(plain) samples=\(surfaceSamples.sorted())")
                    for collection in collections {
                        var rows: [Int] = []
                        var pending = [collection]
                        while let id = pending.popLast() {
                            if let model = backend.model(id: id) {
                                if model.property(.accessibilityIdentifier)?.stringValue?.hasPrefix("outliner.block.") == true { rows.append(id) }
                                pending.append(contentsOf: model.children)
                            } else if let model = backend.extensionModel(id: id) { pending.append(contentsOf: model.children) }
                        }
                        precondition(rows.count <= 32, "A mobile outline collection mounted more than 32 block rows")
                        print("VIRTUALIZATION phase=\(phase) collection=\(collection) rows=\(rows.count) ids=\(rows.map(String.init).joined(separator: ","))")
                    }
                }
                @MainActor func targetWindowReady() -> Bool {
                    let expected = Int(ProcessInfo.processInfo.environment["LOGSEQ_BENCH_EXPECTED_ROWS"] ?? "1") ?? 1
                    var pending = backend.rootIDs
                    while let id = pending.popLast() {
                        if let model = backend.model(id: id) {
                            if let attrs = model.property(.dataAttrs)?.stringValue {
                                let count = attrs.split(separator: "\u{1e}").compactMap { record -> Int? in
                                    let pair = record.split(separator: "\u{1f}", maxSplits: 1)
                                    return pair.count == 2 && pair[0] == "data-virtual-count" ? Int(pair[1]) : nil
                                }.first ?? 0
                                if count >= expected && !model.children.isEmpty { return true }
                            }
                            pending.append(contentsOf: model.children)
                        } else if let model = backend.extensionModel(id: id) { pending.append(contentsOf: model.children) }
                    }
                    return false
                }
                @MainActor func waitForTargetWindow() async {
                    for _ in 0..<250 {
                        if targetWindowReady() { return }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    preconditionFailure("The benchmark page did not become ready")
                }
                report("root")
                if ProcessInfo.processInfo.environment["LOGSEQ_AUTO_SIDEBAR"] == "1" {
                    @MainActor func find(_ identifier: String?, kind: LUINodeKind? = nil) -> Int? {
                        var pending = backend.rootIDs
                        while let id = pending.popLast() {
                            if let model = backend.model(id: id) {
                                if let identifier, model.property(.accessibilityIdentifier)?.stringValue == identifier { return id }
                                if let kind, model.kind == kind { return id }
                                pending.append(contentsOf: model.children)
                            } else if let model = backend.extensionModel(id: id) { pending.append(contentsOf: model.children) }
                        }
                        return nil
                    }
                    for index in 0..<6 {
                        guard let drawer = find(nil, kind: .drawer) else { print("FRAME_BENCH error=no-drawer"); break }
                        FrameBenchmark.shared.begin("open-\(index)")
                        try? backend.performToggle(node: drawer, checked: true)
                        try? await Task.sleep(for: .milliseconds(800))
                        FrameBenchmark.shared.finish()
                        guard let page = find("link.sidebar.page." + benchmarkPageUUID) else { print("FRAME_BENCH error=no-page"); break }
                        FrameBenchmark.shared.begin("select-\(index)")
                        try? backend.performPress(node: page)
                        try? await Task.sleep(for: .milliseconds(1000))
                        await waitForTargetWindow()
                        FrameBenchmark.shared.finish()
                    }
                    report("after-frames")
                    print("FRAME_BENCH complete")
                }
                if ProcessInfo.processInfo.environment["LOGSEQ_AUTO_SCROLL"] == "1" {
                    await waitForTargetWindow()
                    @MainActor func mountedIdentifiers() -> [String] {
                        var identifiers: [String] = []
                        var pending = backend.rootIDs
                        while let id = pending.popLast() {
                            if let model = backend.model(id: id) {
                                if let value = model.property(.accessibilityIdentifier)?.stringValue, value.hasPrefix("outliner.block.") { identifiers.append(value) }
                                pending.append(contentsOf: model.children)
                            } else if let model = backend.extensionModel(id: id) { pending.append(contentsOf: model.children) }
                        }
                        return identifiers
                    }
                    let initialIdentifiers = Set(mountedIdentifiers())
                    let expected = Int(ProcessInfo.processInfo.environment["LOGSEQ_BENCH_EXPECTED_ROWS"] ?? "1") ?? 1
                    @MainActor func scrollViews(_ view: UIView) -> [UIScrollView] {
                        guard !view.isHidden, view.alpha > 0.01 else { return [] }
                        return ((view as? UIScrollView).map { [$0] } ?? [])
                            + view.subviews.flatMap(scrollViews)
                    }
                    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
                    if let scroll = windows.flatMap({ scrollViews($0) }).filter({ $0.bounds.height > 100 && $0.isUserInteractionEnabled }).max(by: { $0.contentSize.height < $1.contentSize.height }) {
                        for fraction in [0.05, 0.5, 1.0, 0.0] {
                            FrameBenchmark.shared.begin("scroll-\(fraction)")
                            let end = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                            scroll.setContentOffset(CGPoint(x: 0, y: end * fraction), animated: true)
                            try? await Task.sleep(for: .milliseconds(1500))
                            FrameBenchmark.shared.finish()
                            report("scroll-\(fraction)")
                            let identifiers = mountedIdentifiers()
                            if fraction >= 0.5 && expected > 32 {
                                precondition(Set(identifiers) != initialIdentifiers,
                                             "Scrolling must hydrate the destination instead of displaying a blank span")
                            }
                            if fraction == 1, initialIdentifiers.contains("outliner.block.e2e30000-0000-4000-9000-000000001000") {
                                let last = "outliner.block.e2e30000-0000-4000-9000-" + String(format: "%012d", expected + 999)
                                precondition(identifiers.contains(last), "Scrolling to the end must mount the final fixture block")
                            }
                            print("SCROLL_WINDOW fraction=\(fraction) offset=\(scroll.contentOffset.y) content_height=\(scroll.contentSize.height) count=\(identifiers.count) identifiers=\(identifiers.sorted().joined(separator: ","))")
                        }
                    } else { print("SCROLL_WINDOW error=no-scroll") }
                }
                if ProcessInfo.processInfo.environment["LOGSEQ_UI_PAGE_KIND"] == "node", let extensionID {
                    try? backend.performExtensionEvent(node: extensionID, name: "open-node", values: ["uuid": .string(benchmarkPageUUID)])
                    try? await Task.sleep(for: .seconds(3))
                    report("node")
                }
                if ProcessInfo.processInfo.environment["LOGSEQ_BENCH_EXIT"] == "1" {
                    print("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                }
            }
        }
    }
}
