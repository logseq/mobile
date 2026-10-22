import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class ComposerTagEffects: LGEffectExecuting {
    var tagged: [[String: Any]] = []
    var plain: [String] = []
    var failTagged = true

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        switch effect.kind {
        case "load-composer-tags":
            return LGEffectResolution(succeeded: true, message: #"{"ok":true,"result":{"selectedGraphId":"composer-tags","composerTagChoices":[{"uuid":"project","title":"Project"}]}}"#)
        case "send-tagged":
            tagged.append(try! JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as! [String: Any])
            return LGEffectResolution(succeeded: !failTagged, message: failTagged ? "Storage failed" : "", output: .discard)
        case "send-capture": plain.append(effect.text)
        default: break
        }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct ComposerTagsCheck {
    @MainActor static func main() async throws {
        let effects = ComposerTagEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"composer-tags","graphName":"Composer tags","isGraphUnlocked":true,"outlinerRows":[]}}"#)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        try runtime.applyHostUpdate(kind: "restore-ui-session", payload: #"{"graphId":"composer-tags","destination":"journals","assets":[],"composerExpanded":true,"searchOpen":false,"query":"","appPath":[],"searchPath":[],"selectedPageId":null,"settingsOpen":false,"recentGraphIds":[]}"#)
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        func press(_ identifier: String) throws {
            guard let id = find(identifier) else { throw failure("Missing control: " + identifier) }
            do { try backend.performPress(node: id) }
            catch { throw failure("Cannot press " + identifier + ": " + String(describing: error)) }
        }
        func nativeComposer() -> UITextView? {
            views(window).compactMap { $0 as? UITextView }.first
        }
        try await wait("The composer must use a native text view") { nativeComposer() != nil }
        let composer = nativeComposer()!
        composer.becomeFirstResponder()
        composer.insertText("Native note 中文")
        try await Task.sleep(for: .milliseconds(350))
        guard let attachment = frames[find("button.attachment")!], let status = frames[find("button.task-status")!],
              let tagFrame = frames[find("button.composer.tags")!], attachment.minX < status.minX, status.minX < tagFrame.minX else {
            throw failure("Hashtag must follow attachment and task status controls")
        }
        func openTags() async throws {
            try press("button.composer.tags")
            try await wait("The shared tag picker must present native search") {
                find("view.edit.option.composer.tags.project") != nil && views(window).contains { $0 is UISearchTextField }
            }
        }
        func create(_ title: String) async throws {
            guard let search = views(window).compactMap({ $0 as? UISearchTextField }).first else {
                throw failure("Tags must use the native property search control")
            }
            search.becomeFirstResponder()
            search.insertText(title)
            try await wait("Typing must offer explicit tag creation") { find("view.edit.create.composer.tags") != nil }
            try press("view.edit.create.composer.tags")
        }
        func closeTags(_ action: String) async throws {
            try press("view.edit." + action + ".composer.tags")
            try await wait("The native picker must dismiss") {
                find("view.edit.value.composer.tags") == nil && window.rootViewController?.presentedViewController == nil
            }
        }
        try await openTags()
        try press("view.edit.option.composer.tags.project")
        try await closeTags("save")
        try await wait("Selected tags must become removable chips") { find("button.composer.tag.remove.project") != nil }
        try await openTags()
        try await create("Mobile")
        try await closeTags("save")
        try await wait("New tags must become removable chips") { find("button.composer.tag.remove.new:mobile") != nil }
        try press("button.composer.tag.remove.project")
        try await openTags()
        try await create("Discard")
        try await closeTags("cancel")
        guard find("button.composer.tag.remove.new:discard") == nil,
              nativeComposer() === composer, composer.text == "Native note 中文" else {
            throw failure("Cancel and tag editing must preserve the native composer and its draft")
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("composer-tag-chip.png"))
        try press("button.send")
        try await wait("Send must carry the staged tags") { effects.tagged.count == 1 }
        guard effects.tagged[0]["text"] as? String == "Native note 中文",
              let tags = effects.tagged[0]["tags"] as? [String: Any], tags["newValues"] as? [String] == ["Mobile"],
              tags["selectedValues"] as? [String] == [] else {
            throw failure("Tag selection must travel separately from the unchanged capture text")
        }
        try await wait("Failed captures must recover their draft and chips") {
            nativeComposer()?.text == "Native note 中文" && find("button.composer.tag.remove.new:mobile") != nil
        }
        try press("button.composer.tag.remove.new:mobile")
        try press("button.send")
        try await wait("Retry must honor removal of recovered tags") { effects.plain == ["Native note 中文"] }
        try await wait("Successful retry must clear the composer") { nativeComposer()?.text == "" }
        effects.failTagged = false
        try await openTags()
        try press("view.edit.option.composer.tags.project")
        try await closeTags("save")
        nativeComposer()!.insertText("Accepted tagged note")
        try await wait("Native typing must enable Send") {
            find("button.send").flatMap { backend.model(id: $0)?.isEnabled } == true
        }
        try press("button.send")
        try await wait("An accepted tagged capture clears its draft and chips") {
            effects.tagged.count == 2 && nativeComposer()?.text == "" && find("button.composer.tag.remove.project") == nil
        }
        try await openTags()
        try press("view.edit.option.composer.tags.project")
        try await closeTags("save")
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"other","graphName":"Other","isGraphUnlocked":true,"outlinerRows":[]}}"#)
        try await wait("Switching graphs must clear the previous graph's tag chips") { find("button.composer.tag.remove.project") == nil }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: native composer tags select, create, cancel, remove, recover failed captures, retry without removed tags and stay graph-scoped")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ComposerTags", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
