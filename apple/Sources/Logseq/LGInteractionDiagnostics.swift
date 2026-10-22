import Foundation
#if os(iOS)
import UIKit
#endif

/// Temporary device diagnostics: identifiers and geometry only, never note text.
@MainActor enum LGInteractionDiagnostics {
    static func event(_ name: String, _ detail: String = "") {
        #if (DEBUG || LOGSEQ_INTERACTION_DIAGNOSTICS) && os(iOS)
        InteractionMonitor.shared.record(name, detail)
        #endif
    }

    #if os(iOS)
    static func editor(_ view: UITextView, blockID: String, event name: String) {
        #if DEBUG || LOGSEQ_INTERACTION_DIAGNOSTICS
        InteractionMonitor.shared.watch(view)
        event(name, "block=\(blockID) view=\(ObjectIdentifier(view)) attached=\(view.window != nil) responder=\(view.isFirstResponder)")
        #endif
    }
    #endif
}

#if (DEBUG || LOGSEQ_INTERACTION_DIAGNOSTICS) && os(iOS)
@MainActor private final class InteractionMonitor: NSObject {
    static let shared = InteractionMonitor()
    private weak var editor: UITextView?
    private weak var scroll: UIScrollView?
    private weak var window: UIWindow?
    private var displayLink: CADisplayLink?
    private var lastFrame = ""
    private let writer = InteractionLogWriter()

    private override init() {
        super.init()
        record("session", "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "debug") system=\(UIDevice.current.systemVersion)")
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                     UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(notification), name: name, object: nil)
        }
    }

    func record(_ name: String, _ detail: String) {
        writer.append("\(Int64(Date().timeIntervalSince1970 * 1_000)) \(String(format: "%.4f", ProcessInfo.processInfo.systemUptime)) \(name) \(detail)\n")
    }

    func watch(_ view: UITextView) {
        editor = view
        if let window = view.window { self.window = window }
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView { self.scroll = scroll; break }
            ancestor = current.superview
        }
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func notification(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] ?? 0
        record("notification", "name=\(note.name.rawValue) keyboard=\(end) duration=\(duration)")
    }

    @objc private func frame() {
        if let editor, editor.window != nil { watch(editor) }
        var detail = "editor=none"
        if let editor {
            detail = "editor=\(ObjectIdentifier(editor)) attached=\(editor.window != nil) responder=\(editor.isFirstResponder) frame=\(editor.convert(editor.bounds, to: window)) bounds=\(editor.bounds) selection=\(editor.selectedRange) marked=\(editor.markedTextRange != nil)"
        }
        if let scroll {
            detail += " scroll=\(ObjectIdentifier(scroll)) offset=\(scroll.contentOffset) size=\(scroll.contentSize) viewport=\(scroll.bounds.size) inset=\(scroll.adjustedContentInset) tracking=\(scroll.isTracking) dragging=\(scroll.isDragging) decelerating=\(scroll.isDecelerating)"
        }
        if let window { detail += " safeArea=\(window.safeAreaInsets)" }
        guard detail != lastFrame else { return }
        lastFrame = detail
        record("frame", detail)
    }
}

/// File I/O stays off the main thread and is batched to avoid disturbing a repro.
private final class InteractionLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.logseq.interaction-diagnostics", qos: .utility)
    private var pending = Data()
    private var scheduled = false
    private let url = URL.cachesDirectory.appendingPathComponent("interaction-debug.log")

    func append(_ line: String) {
        queue.async { [self] in
            pending.append(contentsOf: line.utf8)
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + 0.25) { [self] in flush() }
        }
    }

    private func flush() {
        defer { pending.removeAll(keepingCapacity: true); scheduled = false }
        do {
            let files = FileManager.default
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue > 4_000_000 {
                let previous = url.deletingLastPathComponent().appendingPathComponent("interaction-debug.previous.log")
                try? files.removeItem(at: previous)
                try files.moveItem(at: url, to: previous)
            }
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: pending)
        } catch {
            // Diagnostics must never interfere with editing or graph writes.
        }
    }
}
#endif
