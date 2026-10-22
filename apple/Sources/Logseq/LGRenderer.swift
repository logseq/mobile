import LUIAppleBackend
import Observation
import SwiftUI

public enum LGRendererEventKind: Equatable, Sendable {
    case appear
    case press
    case longPress
    case textChanged
    case submit
    case toggleChanged
    case change
    case valueChanged
    case dismiss
    case doublePress
    case scrollCompleted
    case visibleRange
    case picked
    case `extension`
}

public struct LGRendererEvent: Equatable, Sendable {
    public let kind: LGRendererEventKind
    public let nodeID: Int
    public let text: String?
    public let checked: Bool?
    public let value: Double?
    public let extensionIdentifier: String?
    public let extensionName: String?
    public let extensionValues: [String: LUIExtensionValue]?
    public let payload: String?
    public let first: Int?
    public let last: Int?
    public let token: Int?
    public let outcome: String?

    public init(
        kind: LGRendererEventKind,
        nodeID: Int,
        text: String? = nil,
        checked: Bool? = nil,
        value: Double? = nil,
        extensionIdentifier: String? = nil,
        extensionName: String? = nil,
        extensionValues: [String: LUIExtensionValue]? = nil,
        payload: String? = nil,
        first: Int? = nil,
        last: Int? = nil,
        token: Int? = nil,
        outcome: String? = nil
    ) {
        self.kind = kind
        self.nodeID = nodeID
        self.text = text
        self.checked = checked
        self.value = value
        self.extensionIdentifier = extensionIdentifier
        self.extensionName = extensionName
        self.extensionValues = extensionValues
        self.payload = payload
        self.first = first
        self.last = last
        self.token = token
        self.outcome = outcome
    }
}

enum LGIconPolicy {
    static var icons: [String: LUIAppleIconSource] {
        var result: [String: LUIAppleIconSource] = [
            "calendar": .assetName("calendar"),
            "add": .assetName("plus"),
            "composer-add": .systemName("plus"),
            "composer-file": .systemName("doc"),
            "arrow-up": .systemName("arrow.up"),
            "close": .assetName("close"),
            "chevron-down": .assetName("chevron_down"),
            "document": .assetName("document"),
            "disclosure-down": .assetName("disclosure_down"),
            "disclosure-right": .assetName("disclosure_right"),
            "refresh": .systemName("arrow.clockwise"),
            "logo": .assetName("logo"),
            "graph-locked": .systemName("lock"),
            "flashcards": .assetName("flashcards"),
            "folder": .assetName("folder"),
            "graph-local": .assetName("folder"),
            "graph-remote": .assetName("upload"),
            "history": .assetName("history"),
            "more-horiz": .assetName("more_horiz"),
            "search": .assetName("search"),
            "sidebar-toggle": .assetName("sidebar_toggle"),
            "settings": .systemName("gearshape"),
            "star": .assetName("star"),
            "status-dot": .assetName("status_dot"),
            "outliner-bullet": .assetName("outliner_bullet"),
            "priority-low": .assetName("priority_low"),
            "priority-medium": .assetName("priority_medium"),
            "priority-high": .assetName("priority_high"),
            "priority-urgent": .assetName("priority_urgent"),
            "task-backlog": .assetName("task_backlog"),
            "task-canceled": .assetName("task_canceled"),
            "task-doing": .assetName("task_doing"),
            "task-done": .assetName("task_done"),
            "task-review": .assetName("task_review"),
            "task-todo": .assetName("task_todo"),
            "toolbar-attachment": .assetName("paperclip"),
            "toolbar-audio": .assetName("toolbar_audio"),
            "toolbar-camera": .assetName("camera"),
            "composer-photo": .systemName("photo.on.rectangle.angled"),
            "toolbar-copy": .systemName("doc.on.doc"),
            "toolbar-copy-reference": .systemName("r.square"),
            "toolbar-copy-url": .systemName("link"),
            "view-list": .systemName("list.bullet"),
            "view-table": .systemName("tablecells"),
            "view-gallery": .systemName("square.grid.2x2"),
            "view-filter": .systemName("line.3.horizontal.decrease"),
            "view-sort": .systemName("arrow.up.arrow.down"),
            "toolbar-delete": .systemName("trash"),
            "toolbar-hide-keyboard": .assetName("toolbar_hide_keyboard"),
            "toolbar-indent": .assetName("toolbar_indent"),
            "toolbar-move-down": .systemName("arrow.down"),
            "toolbar-move-up": .systemName("arrow.up"),
            "toolbar-outdent": .assetName("toolbar_outdent"),
            "toolbar-tag": .assetName("toolbar_tag"),
            "toolbar-task": .assetName("task_done"),
            "toolbar-unselect": .systemName("xmark"),
            "trash": .systemName("trash"),
        ]
        result["calendar"] = .systemName("calendar")
        result["more-horiz"] = .systemName("ellipsis")
        result["add"] = .systemName("plus")
        result["document"] = .systemName("doc.text")
        result["folder"] = .systemName("folder")
        result["graph-local"] = .systemName("cylinder.split.1x2")
        result["graph-remote"] = .systemName("icloud")
        result["history"] = .systemName("clock")
        result["search"] = .systemName("magnifyingglass")
        result["star"] = .systemName("star")
        result["toolbar-attachment"] = .systemName("paperclip")
        result["toolbar-audio"] = .systemName("mic")
        result["toolbar-camera"] = .systemName("camera")
        result["toolbar-hide-keyboard"] = .systemName("keyboard.chevron.compact.down")
        result["toolbar-indent"] = .systemName("arrow.right")
        result["toolbar-move-down"] = .systemName("arrow.down")
        result["toolbar-move-up"] = .systemName("arrow.up")
        result["toolbar-outdent"] = .systemName("arrow.left")
        result["toolbar-tag"] = .systemName("number")
        result["toolbar-task"] = .systemName("checkmark.square")
        return result
    }
}

@MainActor
@Observable
public final class LGRenderer {
    public private(set) var rootID: Int?

    @ObservationIgnored
    public var onEvent: ((LGRendererEvent) -> Void)?

    @ObservationIgnored
    let backend: LUIAppleBackend

    @ObservationIgnored
    let imagePreviews = LGImagePreviewStore()

    public init() {
        let backend = Self.makeBackend()
        self.backend = backend
        backend.onEvent = { [weak self] event in
            guard let mapped = Self.map(event) else { return }
            self?.receive(mapped)
        }
    }

    private static func makeBackend() -> LUIAppleBackend {
        do {
            let backend = try LUIAppleBackend(
                appIcons: LGIconPolicy.icons,
                appIconBundle: .module,
                extensionRegistry: LGExtensionRegistry.makeRegistry()
            )
            // Effects like local-graph deletion resolve through several RPCs,
            // each emitting a patch on its own runloop turn. Coalescing merges
            // the burst into one view commit; without it iOS's collection view
            // replays stale section mutations and asserts.
            backend.coalescesCommits = true
            return backend
        } catch {
            preconditionFailure(
                "Invalid LG extension registry: \(String(describing: error))"
            )
        }
    }

    public func apply(patchJSON: String) throws {
        try backend.apply(json: patchJSON)
        rootID = backend.rootIDs.first
    }

    public func apply(decoded: LUIAppleBackend.DecodedPatchBatch) throws {
        try backend.apply(decoded: decoded)
        rootID = backend.rootIDs.first
    }

    func receiveForTesting(_ event: LGRendererEvent) {
        receive(event)
    }

    private func receive(_ event: LGRendererEvent) {
        guard let onEvent else { return }
        onEvent(event)
    }

    private static func map(_ event: LUIEvent) -> LGRendererEvent? {
        switch event {
        case .appear(let node):
            return LGRendererEvent(kind: .appear, nodeID: node)
        case .press(let node):
            return LGRendererEvent(kind: .press, nodeID: node)
        case .longPress(let node):
            return LGRendererEvent(kind: .longPress, nodeID: node)
        case .textChanged(let node, let text):
            return LGRendererEvent(kind: .textChanged, nodeID: node, text: text)
        case .submit(let node):
            return LGRendererEvent(kind: .submit, nodeID: node)
        case .toggleChanged(let node, let checked):
            return LGRendererEvent(
                kind: .toggleChanged,
                nodeID: node,
                checked: checked
            )
        case .change(let node):
            return LGRendererEvent(kind: .change, nodeID: node)
        case .valueChanged(let node, let value):
            return LGRendererEvent(kind: .valueChanged, nodeID: node, value: value)
        case .dismiss(let node):
            return LGRendererEvent(kind: .dismiss, nodeID: node)
        case .doublePress(let node):
            return LGRendererEvent(kind: .doublePress, nodeID: node)
        case .scrollCompleted(let node, let token, let outcome):
            return LGRendererEvent(
                kind: .scrollCompleted,
                nodeID: node,
                token: token,
                outcome: outcome
            )
        case .visibleRange(let node, let first, let last):
            return LGRendererEvent(
                kind: .visibleRange,
                nodeID: node,
                first: first,
                last: last
            )
        case .picked(let node, let payload):
            return LGRendererEvent(kind: .picked, nodeID: node, payload: payload)
        case .extension(let node, let identifier, let name, let values):
            return LGRendererEvent(
                kind: .extension,
                nodeID: node,
                extensionIdentifier: identifier,
                extensionName: name,
                extensionValues: values
            )
        // The Logseq core ABI exports no pointer-level or context-menu
        // entries (see shared/native/logseq_core_ffi.h), so these
        // events are dropped — matching the Kotlin LuiDispatch.
        case .pressDetail, .pointerDown, .pointerUp, .pointerEnter,
             .pointerLeave, .contextMenuPress:
            return nil
        }
    }
}

public struct LGRendererRoot: View {
    private let renderer: LGRenderer

    public init(renderer: LGRenderer) {
        self.renderer = renderer
    }

    @ViewBuilder
    public var body: some View {
        if let rootID = renderer.rootID {
            LUISwiftUIRoot(backend: renderer.backend, rootID: rootID)
                // Preserve the declared item order even when a menu opens upward.
                .menuOrder(.fixed)
                .modifier(LGImagePreviewModifier(store: renderer.imagePreviews))
        } else {
            EmptyView()
        }
    }
}
