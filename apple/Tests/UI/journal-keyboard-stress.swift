import SwiftUI
import UIKit
import WebKit
@testable import Logseq
@testable import LUIAppleBackend

// Run with LOGSEQ_RUNTIME_CHECK_TIMEOUT=180 using run-simulator-runtime-check.py.
private enum BlockKind: String, CaseIterable {
    case short, blank, wrapped, multiline, cjk, rtl, emoji, nested, task, link, code, math, image
}

private struct StressBlock {
    let id: String
    let kind: BlockKind
    let title: String
    let row: [String: Any]

    init(_ kind: BlockKind, index: Int, page: Int, day: Int, images: [URL]) {
        id = "stress-\(index)"
        self.kind = kind
        var title: String
        var depth = 0
        var block: [String: Any] = ["uuid": id, "pageId": "day-\(page)", "journalDay": day,
                                    "journalTitle": "Journal \(page + 1)"]
        switch kind {
        case .short:
            title = "OK \(index)"
        case .blank:
            title = ""
        case .wrapped:
            title = "Release notes for the weekly review. Verify the exported transcript, time zone, workspace permissions, and offline sync before distributing the final build. Follow up with the mobile team after the review."
        case .multiline:
            title = """
            Review notes
            The layout should settle after the keyboard closes.
            Reopen this block near the bottom of the journal.
            Check the selected line after scrolling back.
            """
        case .cjk:
            title = "今天整理日志并测试长列表。日本語の改行位置を確認する。한국어 입력 중에도 커서가 보여야 합니다。下一段不加空格继续输入以触发自动换行。"
        case .rtl:
            title = "مراجعة الملاحظات اليومية — תיקון מיקום הסמן 123 ثم اختبار لوحة المفاتيح."
        case .emoji:
            title = "👩🏽‍💻 🧑‍🧑‍🧒‍🧒 🇨🇳 cafe\u{301} ／ Đồng bộ — Text after composed characters"
        case .nested:
            title = "Nested release checklist item \(index)"
            depth = index % 5 + 1
        case .task:
            title = "Verify assets on the phone before closing TODO \(index)"
            block["isTask"] = true
            block["status"] = ["uuid": "doing-status", "title": "Doing"]
            block["priority"] = ["uuid": "high-priority", "title": "High"]
        case .link:
            let url = "https://example.com/projects/mobile/releases/2026-11-24?filter=unresolved"
            title = "[Release notes](\(url)) Review zoom and selection on the last line."
            block["markup"] = [
                ["type": "link", "url": url, "children": [["type": "text", "text": "Release notes"]]],
                ["type": "text", "text": " Review zoom and selection on the last line."],
            ]
        case .code:
            title = """
            let journalIDs = dates.map { $0.formatted() }
            for id in journalIDs {
                print("Validating journal: " + id)
            }
            """
            block["displayType"] = "code"
            block["markup"] = [["type": "codeBlock", "style": "swift", "text": title]]
        case .math:
            title = #"\frac{1}{\sqrt{x^2+1}} = (x^2+1)^{-1/2}"#
            block["displayType"] = "math"
            block["markup"] = [["type": "math", "style": "display", "text": title]]
        case .image:
            title = "Journal photo \(index).png"
            block["isAsset"] = true
            block["assetType"] = "image/png"
            block["localPath"] = images[(index / 2) % images.count].path
        }
        self.title = title
        block["title"] = title
        row = ["depth": depth, "hasChildren": kind == .short, "block": block]
    }
}

@MainActor private final class StressEffects: LGEffectExecuting {
    let blocks: [String: StressBlock]
    let snapshotBase: [String: Any]
    private(set) var editing: (id: String, offset: Int)?
    private(set) var lastEdit: (id: String, offset: Int)?

    init(images: [URL]) {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24))!
        let kinds: [BlockKind] = [.wrapped, .multiline, .short, .nested, .nested, .emoji, .image, .cjk,
                                  .link, .rtl, .short, .blank, .task, .image, .code, .short, .math, .wrapped,
                                  .emoji, .image, .cjk, .task]
        let rows = (0..<50).flatMap { page in
            let date = calendar.date(byAdding: .day, value: -page, to: first)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let day = parts.year! * 10000 + parts.month! * 100 + parts.day!
            return kinds.enumerated().map { offset, kind in
                StressBlock(kind, index: page * kinds.count + offset, page: page, day: day, images: images)
            }
        }
        blocks = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var agenda: [String: Any] = ["graphId": "stress", "page": "day-0", "day": 20261124,
                                     "enabled": true, "success": true]
        for section in ["overdue", "doing", "planned"] {
            agenda[section] = (1...6).map { index in
                let id = "\(section)-\(index)"
                return ["uuid": id, "block": ["uuid": id, "title": "Task \(index) \(section)", "pageId": "other-page"]]
            }
        }
        snapshotBase = ["selectedGraphId": "stress", "graphName": "Keyboard stress",
                        "outlinerRows": rows.map(\.row), "journalTasks": agenda]
    }

    func snapshot() throws -> String {
        var result = snapshotBase
        if let editing, let block = blocks[editing.id] {
            result["outlinerState"] = ["editing": ["uuid": editing.id, "title": block.title,
                                                   "caretUTF16Offset": editing.offset]]
        } else {
            result["outlinerState"] = ["selectedBlockIds": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        return String(decoding: data, as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "tap-outliner-block", let block = blocks[effect.text] {
            editing = (block.id, block.title.utf16.count)
            lastEdit = editing
        } else if effect.kind == "editor-outliner-event",
           let payload = try? JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as? [String: Any],
           payload["type"] as? String == "tapBlock",
           let id = payload["uuid"] as? String, let block = blocks[id] {
            editing = (id, payload["caretUTF16Offset"] as? Int ?? block.title.utf16.count)
            lastEdit = editing
        } else if effect.kind == "outliner-toolbar", effect.text == "hideKeyboard" {
            editing = nil
        } else {
            return .init(succeeded: true, message: "", output: .discard)
        }
        do { return .init(succeeded: true, message: try snapshot()) }
        catch { return .init(succeeded: false, message: error.localizedDescription, output: .discard) }
    }
}

@MainActor private final class FrameTrace: NSObject {
    struct Sample {
        let y: CGFloat?
        let offset: CGFloat
    }

    private let read: () -> Sample
    private(set) var samples: [Sample] = []

    init(read: @escaping () -> Sample) { self.read = read }

    func record(_ action: () async throws -> Void) async throws -> [Sample] {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        sample()
        try await action()
        try await Task.sleep(for: .milliseconds(850))
        return samples
    }

    @objc private func sample() { samples.append(read()) }
}

@main struct JournalKeyboardStressCheck {
    @MainActor static func main() async throws {
        let images = try makeImages()
        defer { for url in images { try? FileManager.default.removeItem(at: url) } }
        let effects = StressEffects(images: images)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        if ProcessInfo.processInfo.environment["LOGSEQ_STRESS_DARK"] == "1" {
            window.overrideUserInterfaceStyle = .dark
        }
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
        func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }
        func anchors(in root: UIView) -> [String: UIView] {
            var result: [String: UIView] = [:]
            let prefix = "outliner.block-action."
            for view in views(root) where !view.isHidden && view.bounds.height > 0 {
                if let label = view as? UILabel, let id = label.accessibilityIdentifier, id.hasPrefix(prefix) {
                    result[String(id.dropFirst(prefix.count))] = label
                } else if let marker = view as? OutlinerScrollAnchorMarker.Marker {
                    result[marker.blockID] = marker
                }
            }
            return result
        }
        func editor() -> UITextView? { views(window).compactMap { $0 as? UITextView }.first(where: \.isFirstResponder) }
        func wait(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

        try await wait(950)
        guard let scroll = views(window).compactMap({ $0 as? UIScrollView }).max(by: {
            $0.contentSize.height < $1.contentSize.height
        }), scroll.contentSize.height > 10_000 else { throw failure("Stress fixture did not mount a long journal list") }
        let regularInset = scroll.adjustedContentInset.bottom
        let fieldPrefix = "field.outliner.block."
        var attempts = 0
        var completed = 0
        var reopened = 0
        var covered = [BlockKind: Int]()
        var failures = [String]()
        var maxDrift: CGFloat = 0
        var maxTransient: CGFloat = 0
        var previous: StressBlock?

        for position in [0.0, 0.08, 0.28, 0.51, 0.74, 0.92, 1.0] {
            for round in 0..<6 {
                let reopen = round == 5
                if !reopen {
                    for _ in 0..<3 {
                        let top = -scroll.adjustedContentInset.top
                        let end = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                        let y = min(end, top + (end - top) * position + CGFloat(round * 167))
                        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                        try await wait(160)
                    }
                }
                let mounted = anchors(in: scroll)
                let viewport = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
                    .inset(by: UIEdgeInsets(top: 24, left: 0, bottom: 80, right: 0))
                let target: StressBlock?
                if reopen, let previous, let anchor = mounted[previous.id], frame(anchor).intersects(viewport) {
                    target = previous
                    reopened += 1
                } else {
                    target = mounted.compactMap { id, anchor -> StressBlock? in
                        guard let block = effects.blocks[id], block.kind != .image,
                              frame(anchor).intersection(viewport).height >= 20 else { return nil }
                        return block
                    }.sorted { lhs, rhs in
                        let left = covered[lhs.kind, default: 0], right = covered[rhs.kind, default: 0]
                        if left != right { return left < right }
                        let y = viewport.minY + viewport.height * (round % 3 == 0 ? 0.40 : 0.85)
                        return (abs(frame(mounted[lhs.id]!).midY - y), lhs.id)
                            < (abs(frame(mounted[rhs.id]!).midY - y), rhs.id)
                    }.first
                }
                guard let block = target, let anchor = mounted[block.id] else {
                    failures.append("No editable block at fraction \(position), round \(round)")
                    continue
                }
                attempts += 1
                previous = block
                let context = "\(block.id) \(block.kind.rawValue) at \(position) round \(round)"
                do {
                    let anchorY = frame(anchor).minY
                    let initialOffset = scroll.contentOffset.y
                    let trace = FrameTrace {
                        let mounted = anchors(in: scroll)
                        let y = mounted[block.id].map { frame($0).minY }
                        return .init(y: y, offset: scroll.contentOffset.y)
                    }
                    let opening = try await trace.record {
                        if let label = anchor as? UILabel, let nativeRow = label.superview as? OutlinerTextRowView {
                            let visible = frame(label).intersection(viewport)
                            let y = visible.minY - frame(label).minY + visible.height * (round % 2 == 0 ? 0.25 : 0.75)
                            let x = block.kind == .link ? label.bounds.maxX - 7 : min(54, label.bounds.midX)
                            nativeRow.activateTitle(at: CGPoint(x: x, y: y))
                        } else if block.kind == .code, let code = node("outliner.code.content." + block.id) {
                            try backend.performPress(node: code)
                        } else if block.kind == .math {
                            try await tapFormula(near: anchor, frame: frame, views: views)
                        } else {
                            throw failure("No native title action for \(context)")
                        }
                    }
                    guard let field = editor(), field.accessibilityIdentifier == fieldPrefix + block.id,
                          let selection = field.selectedTextRange, let request = effects.lastEdit, request.id == block.id,
                          let toolbar = views(window).compactMap({ $0 as? OutlinerEditorToolbarGuide.Probe }).first,
                          let dismiss = node("button.outliner.editor.hideKeyboard"),
                          scroll.adjustedContentInset.bottom > regularInset + 100 else {
                        throw failure("Tap did not focus with a docked keyboard for \(context)")
                    }
                    let fixedOffset = field.selectedRange
                    let validOffsets = Set(block.title.indices.map { $0.utf16Offset(in: block.title) } + [block.title.utf16.count])
                    let caret = field.convert(field.caretRect(for: selection.end), to: window)
                    let visible = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
                    let bottom = min(frame(toolbar).minY, visible.maxY)
                    let openY = anchors(in: scroll)[block.id].map { frame($0).minY } ?? frame(field).minY
                    let excursion = opening.compactMap(\.y).map {
                        max(0, min(anchorY, openY) - $0, $0 - max(anchorY, openY))
                    }.max() ?? .infinity
                    var issues: [String] = []
                    if fixedOffset != NSRange(location: request.offset, length: 0) || !validOffsets.contains(request.offset) {
                        issues.append("caret request \(request.offset) applied as \(fixedOffset)")
                    }
                    if caret.minY < visible.minY + 1 || caret.maxY > bottom - 2 {
                        issues.append("obscured caret \(caret.minY)…\(caret.maxY) visible \(visible.minY)…\(bottom)")
                    }
                    if excursion > 6 {
                        issues.append("opening exceeded its settled travel by \(excursion)pt")
                    }
                    if !issues.isEmpty, failures.count < 4 { saveScreenshot(window, name: "opening-\(block.id)") }
                    let closing = try await FrameTrace {
                        .init(y: anchors(in: scroll)[block.id].map { frame($0).minY }, offset: scroll.contentOffset.y)
                    }.record { try backend.performPress(node: dismiss) }
                    guard editor() == nil, effects.editing == nil,
                          let final = anchors(in: scroll)[block.id] else {
                        throw failure("Block disappeared after toolbar dismissal for \(context)")
                    }
                    let drift = abs(frame(final).minY - openY)
                    let transient = closing.compactMap(\.y).map { abs($0 - openY) }.max() ?? .infinity
                    let missing = closing.filter { $0.y == nil }.count
                    completed += 1
                    covered[block.kind, default: 0] += 1
                    maxDrift = max(maxDrift, drift)
                    maxTransient = max(maxTransient, transient)
                    if drift > 1 || transient > 6 || missing > 0 {
                        issues.append("closing drift \(drift)pt, peak \(transient)pt, missing \(missing)/\(closing.count) frames")
                        if failures.count < 4 { saveScreenshot(window, name: "closing-\(block.id)") }
                    }
                    if !issues.isEmpty { failures.append("\(context): " + issues.joined(separator: ", ")) }
                    print("CASE \(context): caret \(request.offset), y \(anchorY) → \(openY), offset \(initialOffset) → \(opening.last?.offset ?? initialOffset), opening excursion \(excursion)pt, closing drift \(drift)pt, peak \(transient)pt, missing \(missing) frames")
                } catch {
                    failures.append(error.localizedDescription)
                    if let dismiss = node("button.outliner.editor.hideKeyboard") {
                        try? backend.performPress(node: dismiss)
                        try await wait(850)
                    }
                }
            }
        }

        let coverage = BlockKind.allCases.filter { $0 != .image }.map { "\($0.rawValue)=\(covered[$0, default: 0])" }
        print("STRESS completed \(completed)/\(attempts), reopened \(reopened), \(effects.blocks.count) blocks, coverage \(coverage.joined(separator: " "))")
        print("STRESS maximum final drift \(maxDrift)pt, maximum transient \(maxTransient)pt")
        let untested = BlockKind.allCases.filter { $0 != .image && covered[$0, default: 0] == 0 }
        if !untested.isEmpty { failures.append("Untested editable block kinds: \(untested)") }
        for issue in failures { print("STRESS FAIL \(issue)") }
        if !failures.isEmpty { throw failure("\(failures.count) issues across \(attempts) attempted interactions") }
        print("PASS: mixed long journals preserve caret visibility and block position")
    }

    @MainActor private static func saveScreenshot(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png"))
    }

    @MainActor private static func tapFormula(near anchor: UIView, frame: (UIView) -> CGRect,
                                               views: (UIView) -> [UIView]) async throws {
        var ancestor = anchor.superview
        while let view = ancestor {
            let webViews = views(view).compactMap { $0 as? WKWebView }.filter { frame($0).intersects(frame(anchor)) }
            for web in webViews {
                if let clicked = try? await web.evaluateJavaScript("""
                    (() => {
                        const formula = document.querySelector('[data-tex] .katex-html');
                        if (!formula) return false;
                        formula.click();
                        return true;
                    })()
                    """) as? Bool, clicked { return }
            }
            if view is UIScrollView { break }
            ancestor = view.superview
        }
        throw failure("A visible formula could not be tapped")
    }

    @MainActor private static func makeImages() throws -> [URL] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try [CGSize(width: 80, height: 80), CGSize(width: 260, height: 680),
                    CGSize(width: 1200, height: 140)].map { size in
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.systemOrange.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width / 3, height: size.height))
            }
            let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try image.pngData()!.write(to: url)
            return url
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalKeyboardStress", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
