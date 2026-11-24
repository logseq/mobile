import SwiftUI
import LogseqModel
#if os(iOS)
import UIKit

@MainActor
struct OutlinerKeyboardDismissal {
    let dismiss: () async -> Void
    let cancel: () -> Void
}
#endif

struct OutlinerInlineEditor: View {
    let text: String
    let blockID: String
    let desiredCaretUTF16Offset: Int?
    var inputPolicy: String = "{}"
    var selectionRevision: Int = 0
    var focusEnabled: Bool = true
    let onTextChange: (String, Int) -> Void
    var onPaste: ((String, Int) -> Void)? = nil
    var onPasteContent: ((String) -> Void)? = nil
    let onReturn: (String, Int) -> Void
    let onBackspace: (String, Int) -> Void
    let onCaretChange: (Int) -> Void

    #if os(iOS)
    static func prepareForKeyboardDismissal() -> OutlinerKeyboardDismissal? {
        guard let editor = OutlinerEditorViewport.editors.allObjects.first(where: {
            $0.isFirstResponder && $0.window?.isKeyWindow == true
        }) else { return nil }
        editor.prepareForKeyboardDismissal()
        return OutlinerKeyboardDismissal(
            dismiss: { [weak editor] in await editor?.dismissKeyboardBeforeRemovingEditor() },
            cancel: { [weak editor] in editor?.cancelKeyboardDismissal() }
        )
    }
    #endif

    #if os(iOS) && DEBUG
    @ObservedObject private var keyboardHideMonitor = OutlinerKeyboardHideMonitor.shared
    #endif

    var body: some View {
        #if os(iOS)
        let editor = NativeOutlinerTextView(
            blockID: blockID,
            text: text,
            accessibilityIdentifier: "field.outliner.block.\(blockID)",
            desiredCaretUTF16Offset: desiredCaretUTF16Offset,
            inputPolicy: inputPolicy,
            selectionRevision: selectionRevision,
            focusEnabled: focusEnabled,
            onTextChange: onTextChange,
            onPaste: onPaste,
            onPasteContent: onPasteContent,
            onReturn: onReturn,
            onBackspace: onBackspace,
            onCaretChange: onCaretChange
        )
        .frame(minHeight: 24)
        #if DEBUG
        editor
            .onAppear {
                keyboardHideMonitor.editorAppeared(id: blockID)
            }
            .onChange(of: blockID) { previousID, currentID in
                keyboardHideMonitor.editorChanged(from: previousID, to: currentID)
            }
            .onDisappear {
                keyboardHideMonitor.editorDisappeared(id: blockID)
            }
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(
                        "debug.keyboard-hide-count.\(keyboardHideMonitor.hideCount)"
                    )
            }
        #else
        editor
        #endif
        #else
        TextField(
            "Block",
            text: Binding(
                get: { text },
                set: { onTextChange($0, $0.utf16.count) }
            ),
            axis: .vertical
        )
            .font(.body)
            .textFieldStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .onSubmit { onReturn(text, text.utf16.count) }
            .onChange(of: text) { _, value in onCaretChange(value.utf16.count) }
            .accessibilityIdentifier("field.outliner.block.\(blockID)")
        #endif
    }
}

#if os(iOS)
#if DEBUG
@MainActor
private final class OutlinerKeyboardHideMonitor: NSObject, ObservableObject {
    static let shared = OutlinerKeyboardHideMonitor()

    @Published private(set) var hideCount = 0
    private var counter = OutlinerKeyboardHideCounter()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func editorAppeared(id: String) {
        counter.editorAppeared(id: id)
        publish()
    }

    func editorChanged(from previousID: String, to currentID: String) {
        counter.editorChanged(from: previousID, to: currentID)
        publish()
    }

    func editorDisappeared(id: String) {
        counter.editorDisappeared(id: id)
        publish()
        DispatchQueue.main.async { [weak self] in
            self?.finishPendingHandoff()
        }
    }

    @objc private func keyboardWillHide() {
        counter.keyboardWillHide()
        publish()
    }

    private func finishPendingHandoff() {
        counter.finishPendingHandoff()
        publish()
    }

    private func publish() {
        hideCount = counter.hideCount
    }
}
#endif

private struct NativeOutlinerTextView: UIViewRepresentable {
    let blockID: String
    let text: String
    let accessibilityIdentifier: String
    let desiredCaretUTF16Offset: Int?
    var inputPolicy: String = "{}"
    var selectionRevision: Int = 0
    var focusEnabled: Bool = true
    let onTextChange: (String, Int) -> Void
    var onPaste: ((String, Int) -> Void)? = nil
    var onPasteContent: ((String) -> Void)? = nil
    let onReturn: (String, Int) -> Void
    let onBackspace: (String, Int) -> Void
    let onCaretChange: (Int) -> Void

    @Environment(\.outlinerScrollRetention) private var scrollRetention

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = FocusRetainingTextView()
        textView.scrollRetention = scrollRetention
        let coordinator = context.coordinator
        textView.onPasteContent = { [weak coordinator, weak textView] payload in
            guard let coordinator, let textView,
                  let paste = coordinator.parent.onPasteContent else { return false }
            coordinator.localText = textView.text
            coordinator.handoffSelectionRevision = coordinator.parent.selectionRevision
            coordinator.isAwaitingBlockHandoff = true
            paste(payload)
            return true
        }
        textView.onPasteImages = { [weak coordinator, weak textView] images in
            guard let coordinator, let textView, coordinator.parent.onPasteContent != nil,
                  !coordinator.isAwaitingBlockHandoff else { return false }
            let blockID = coordinator.parent.blockID
            let revision = coordinator.parent.selectionRevision
            Task { @MainActor [weak coordinator, weak textView] in
                do {
                    let assets = try await LGImageClipboard.importImages(images)
                    guard let coordinator, let textView, textView.window != nil,
                          coordinator.parent.blockID == blockID,
                          coordinator.parent.selectionRevision == revision,
                          !coordinator.isAwaitingBlockHandoff else {
                        for asset in assets { try? FileManager.default.removeItem(atPath: asset.localPath) }
                        return
                    }
                    let payload = try LGImageClipboard.content(assets, blockID: blockID,
                        before: textView.text ?? "", selection: textView.selectedRange)
                    _ = textView.onPasteContent?(payload)
                } catch {
                    guard let textView, let controller = textView.window?.rootViewController else { return }
                    let alert = UIAlertController(title: String(localized: "Unable to paste image"),
                        message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                    var presenter = controller
                    while let presented = presenter.presentedViewController { presenter = presented }
                    presenter.present(alert, animated: true)
                }
            }
            return true
        }
        textView.backgroundColor = .clear
        OutlinerNativeTextMeasurement.configureTextContainer(textView)
        textView.adjustsFontForContentSizeCategory = true
        applyTextLayout(to: textView)
        applyWritingAssistance(to: textView)
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text
        textView.selectedRange = NSRange(
            location: min(desiredCaretUTF16Offset ?? text.utf16.count, text.utf16.count),
            length: 0
        )
        // Assigning the initial text moves UIKit's selection to the end before
        // the tapped position is restored. Start observing after both writes.
        textView.delegate = coordinator
        coordinator.highlight(textView)
        if focusEnabled { textView.requestFocusWhenAttached() }
        LGInteractionDiagnostics.editor(textView, blockID: blockID, event: "editor.make")
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // The editor's properties can clear before its node is removed. Keep
        // the last native selection until teardown so UIKit cannot reveal a
        // transient empty field during keyboard dismissal.
        guard !blockID.isEmpty else { return }
        (textView as? FocusRetainingTextView)?.scrollRetention = scrollRetention
        applyTextLayout(to: textView)
        applyWritingAssistance(to: textView)
        context.coordinator.parent = self
        let isSameBlock = context.coordinator.activeBlockID == blockID
        // Boundary no-ops acknowledge the request without changing block identity.
        let handoffAcknowledged = context.coordinator.handoffSelectionRevision.map { $0 != selectionRevision } ?? false
        let decision: InlineEditorTextReconciliationDecision = handoffAcknowledged ? .applyModel : InlineEditorTextReconciliationPolicy.decision(
            modelText: text,
            localText: context.coordinator.localText,
            isSameBlock: isSameBlock,
            isAwaitingBlockHandoff: context.coordinator.isAwaitingBlockHandoff
        )
        LGInteractionDiagnostics.editor(textView, blockID: blockID, event: "editor.update")
        LGInteractionDiagnostics.event("editor.reconcile", "same=\(isSameBlock) decision=\(decision) handoff=\(context.coordinator.isAwaitingBlockHandoff) selectionRevision=\(selectionRevision)")
        switch decision {
        case .keepLocal:
            break
        case .acknowledgeLocal:
            context.coordinator.localText = nil
            context.coordinator.isAwaitingBlockHandoff = false
            context.coordinator.handoffSelectionRevision = nil
        case .applyModel:
            context.coordinator.isApplyingModel = true
            defer { context.coordinator.isApplyingModel = false }
            let wasAwaitingHandoff = context.coordinator.isAwaitingBlockHandoff
            let bufferedTyping = wasAwaitingHandoff
                ? context.coordinator.pendingHandoffTyping : ""
            context.coordinator.pendingHandoffTyping = ""
            context.coordinator.localText = nil
            context.coordinator.isAwaitingBlockHandoff = false
            context.coordinator.handoffSelectionRevision = nil
            let selection = textView.selectedRange
            if wasAwaitingHandoff {
                let merged = InlineEditorHandoffMerge.merged(
                    modelText: text,
                    desiredCaretUTF16Offset: desiredCaretUTF16Offset,
                    bufferedTyping: bufferedTyping
                )
                if textView.text != merged.text {
                    textView.text = merged.text
                }
                textView.selectedRange = NSRange(
                    location: merged.caretUTF16Offset,
                    length: 0
                )
                if !bufferedTyping.isEmpty {
                    context.coordinator.selectionRevision = selectionRevision
                    context.coordinator.localText = merged.text
                    let onTextChange = context.coordinator.parent.onTextChange
                    DispatchQueue.main.async {
                        onTextChange(merged.text, merged.caretUTF16Offset)
                    }
                }
            } else {
                let caretUTF16Offset = min(
                    desiredCaretUTF16Offset ?? selection.location, text.utf16.count
                )
                // Caret-only updates acknowledge earlier input; the native
                // editor may already hold a newer caret or word selection.
                let shouldRestoreSelection = !isSameBlock || textView.text != text
                if textView.text != text {
                    textView.text = text
                }
                if shouldRestoreSelection {
                    textView.selectedRange = NSRange(location: caretUTF16Offset, length: 0)
                }
            }
        }
        if decision != .keepLocal {
            context.coordinator.applySelectionRequest(to: textView)
        }
        if !isSameBlock {
            #if DEBUG
            print(
                "Logseq debug: outliner editor responder handoff "
                    + "from=\(context.coordinator.activeBlockID) "
                    + "to=\(accessibilityIdentifier) retained=\(textView.isFirstResponder)"
            )
            #endif
            context.coordinator.activeBlockID = blockID
        }
        textView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.highlight(textView)
        if !isSameBlock {
            (textView as? FocusRetainingTextView)?.revealCaretAfterLayout()
        }
        if !focusEnabled {
            (textView as? FocusRetainingTextView)?.cancelPendingFocus()
        } else if InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: textView.window != nil,
            isFirstResponder: textView.isFirstResponder
        ) {
            (textView as? FocusRetainingTextView)?.requestFocusWhenAttached()
        }
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        LGInteractionDiagnostics.editor(textView, blockID: coordinator.activeBlockID, event: "editor.dismantle")
        textView.delegate = nil
        coordinator.highlightTask?.cancel()
    }

    private func applyTextLayout(to textView: UITextView) {
        let code = NativeEditorInputPolicy.usesCodePresentation(inputPolicy)
        let body = UIFont.preferredFont(forTextStyle: .body)
        let font = code ? UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular) : body
        let inset = OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: font.lineHeight,
            minimumLineHeight: OutlinerLayoutMetrics.titleLineHeight
        )
        textView.font = font
        textView.backgroundColor = code ? UIColor.secondaryLabel.withAlphaComponent(0.08) : .clear
        textView.layer.cornerRadius = code ? 8 : 0
        textView.textContainerInset = UIEdgeInsets(
            top: code ? 12 : inset,
            left: code ? 12 : 0,
            bottom: code ? 12 : inset,
            right: code ? 12 : 0
        )
    }

    private func applyWritingAssistance(to textView: UITextView) {
        let code = NativeEditorInputPolicy.usesCodePresentation(inputPolicy)
        let defaults = UserDefaults.standard
        let spellCheck = defaults.object(forKey: "logseq.editor.spellCheck") as? Bool ?? true
        let autoCorrection = defaults.object(forKey: "logseq.editor.autoCorrection") as? Bool ?? true
        textView.spellCheckingType = !code && spellCheck ? .yes : .no
        textView.autocorrectionType = !code && autoCorrection ? .yes : .no
        textView.autocapitalizationType = code ? .none : .sentences
        textView.smartQuotesType = code ? .no : .default
        textView.smartDashesType = code ? .no : .default
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let font = uiView.font else { return nil }
        let horizontalInset = uiView.textContainerInset.left + uiView.textContainerInset.right
        let measured = OutlinerNativeTextMeasurement.size(
            text: uiView.text,
            font: font,
            width: max(1, width - horizontalInset),
            verticalInset: uiView.textContainerInset.top,
            scale: uiView.traitCollection.displayScale
        )
        return CGSize(width: width, height: measured.height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeOutlinerTextView
        var localText: String?
        var isAwaitingBlockHandoff = false
        var handoffSelectionRevision: Int?
        var pendingHandoffTyping = ""
        var activeBlockID: String
        var isApplyingModel = false
        var selectionRevision: Int
        var highlightTask: Task<Void, Never>?
        private var highlightKey: String?

        init(parent: NativeOutlinerTextView) {
            self.parent = parent
            activeBlockID = parent.blockID
            selectionRevision = parent.selectionRevision
        }

        func highlight(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let policy = (try? JSONSerialization.jsonObject(with: Data(parent.inputPolicy.utf8))) as? [String: Any]
            let language = policy?["language"] as? String ?? ""
            let source = textView.text ?? ""
            let code = policy?["code"] as? Bool == true
            guard code else {
                highlightTask?.cancel()
                if highlightKey != nil { applyHighlighting([], to: textView) }
                highlightKey = nil
                return
            }
            let key = source + "\u{0}" + language
            guard highlightKey != key else { return }
            highlightTask?.cancel()
            highlightKey = key
            highlightTask = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                let tokens = await CodeSyntaxHighlighter.shared.tokens(code: source, language: language)
                guard !Task.isCancelled, let self, let textView, textView.text == source,
                      self.highlightKey == key else { return }
                guard textView.markedTextRange == nil else {
                    self.highlightKey = nil
                    return
                }
                self.applyHighlighting(tokens, to: textView)
            }
        }

        private func applyHighlighting(_ tokens: [CodeSyntaxToken], to textView: UITextView) {
            let selection = textView.selectedRange
            isApplyingModel = true
            textView.textStorage.beginEditing()
            NativeCodeHighlighting.apply(tokens, to: textView.textStorage)
            textView.textStorage.endEditing()
            textView.selectedRange = selection
            textView.typingAttributes[.foregroundColor] = UIColor.label
            isApplyingModel = false
        }

        func applySelectionRequest(to textView: UITextView) {
            guard selectionRevision != parent.selectionRevision else { return }
            selectionRevision = parent.selectionRevision
            guard let caret = parent.desiredCaretUTF16Offset else { return }
            isApplyingModel = true
            defer { isApplyingModel = false }
            textView.selectedRange = NSRange(location: min(max(0, caret), textView.text.utf16.count), length: 0)
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? FocusRetainingTextView)?.revealCaretAfterLayout()
            LGInteractionDiagnostics.editor(textView, blockID: activeBlockID, event: "editor.input")
            localText = textView.text
            guard textView.markedTextRange == nil else { return }
            highlight(textView)
            if (textView as? FocusRetainingTextView)?.isPasting == true, let onPaste = parent.onPaste {
                onPaste(textView.text, textView.selectedRange.location)
            } else {
                parent.onTextChange(textView.text, textView.selectedRange.location)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? FocusRetainingTextView)?.revealCaretAfterLayout()
            if InlineEditorCaretEmissionPolicy.shouldEmit(
                textMatchesModel: textView.text == parent.text,
                isApplyingModel: isApplyingModel
            ) {
                parent.onCaretChange(textView.selectedRange.location)
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            let isShiftReturn = (textView as? FocusRetainingTextView)?.isInsertingLineBreak == true
            let isInlineLineBreak = isShiftReturn && !(NativeEditorInputPolicy.usesCodePresentation(parent.inputPolicy)
                && NativeEditorInputPolicy.allowsLineBreak(parent.inputPolicy))
            if isAwaitingBlockHandoff {
                // Structure events are serialized and rebound to the latest
                // editor by the store. Forward them immediately so fast
                // Return/Backspace input is never swallowed during handoff.
                if isInlineLineBreak {
                    pendingHandoffTyping += "\n"
                } else if replacement == "\n" {
                    parent.onReturn(textView.text, range.location)
                } else if replacement.isEmpty, range.location == 0, range.length == 0 {
                    parent.onBackspace(textView.text, range.length)
                } else if replacement.isEmpty {
                    if !pendingHandoffTyping.isEmpty {
                        pendingHandoffTyping.removeLast()
                    }
                } else {
                    pendingHandoffTyping += replacement
                }
                return false
            }
            if isInlineLineBreak || (textView as? FocusRetainingTextView)?.isPasting == true { return true }
            if textView.markedTextRange == nil, let deletion = NativeEditorInputPolicy.deletingEmptyPair(
                from: textView.text ?? "",
                range: range,
                replacementText: replacement,
                inputPolicy: parent.inputPolicy
            ) {
                textView.text = deletion.text
                textView.selectedRange = NSRange(
                    location: deletion.caretUTF16Offset,
                    length: 0
                )
                localText = deletion.text
                parent.onTextChange(deletion.text, deletion.caretUTF16Offset)
                return false
            }
            if replacement == "\n", !isShiftReturn, NativeEditorInputPolicy.allowsLineBreak(parent.inputPolicy) { return true }
            if replacement == "\n" {
                LGInteractionDiagnostics.editor(textView, blockID: activeBlockID, event: "editor.return")
                var submittedText = textView.text ?? ""
                if range.length > 0 {
                    let value = submittedText as NSString
                    let selectionLocation = min(range.location, value.length)
                    let selectionLength = min(range.length, value.length - selectionLocation)
                    submittedText = value.replacingCharacters(
                        in: NSRange(location: selectionLocation, length: selectionLength),
                        with: ""
                    )
                }
                // Leave the text view untouched until the core hands the
                // editor off to the freshly created block; blanking it here
                // makes the current block flash the caret suffix for a frame.
                localText = textView.text
                isAwaitingBlockHandoff = true
                handoffSelectionRevision = parent.selectionRevision
                parent.onReturn(submittedText, range.location)
                return false
            }
            if replacement.isEmpty, range.location == 0, range.length == 0 {
                LGInteractionDiagnostics.editor(textView, blockID: activeBlockID, event: "editor.backspace")
                isAwaitingBlockHandoff = true
                handoffSelectionRevision = parent.selectionRevision
                parent.onBackspace(textView.text, range.length)
                return false
            }
            return true
        }
    }
}

// The navigation stack's floating chrome is outside the scroll view's UIKit
// adjusted insets. Measure it in the same window as the native caret.
struct OutlinerEditorToolbarGuide: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private var previousFrame: CGRect?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            previousFrame = nil
            OutlinerEditorViewport.toolbars.add(self)
            isUserInteractionEnabled = false
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let frame = convert(bounds, to: window)
            guard frame != previousFrame else { return }
            previousFrame = frame
            for editor in OutlinerEditorViewport.editors.allObjects where editor.window === window {
                editor.revealCaretAfterLayout()
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var outlinerScrollRetention: OutlinerScrollRetention? = nil
}

struct OutlinerScrollAnchorMarker: UIViewRepresentable {
    let blockID: String

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) { view.blockID = blockID }

    final class Marker: UIView {
        var blockID = ""
    }
}

@MainActor @Observable
final class OutlinerScrollRetention {
    private(set) var bottomSpace: CGFloat = 0
    @ObservationIgnored private var scrollObservation: NSKeyValueObservation?
    @ObservationIgnored private var restoration: OutlinerRowAnchor?

    func preserve(_ scroll: UIScrollView, editor: UITextView, bottomSafeArea: CGFloat,
                  keyboardDismissed: @escaping () -> Bool) {
        let keyboardSpace = scroll.adjustedContentInset.bottom - bottomSafeArea
        let amountPastEnd = ceil(scroll.contentOffset.y - end(of: scroll, bottomInset: bottomSafeArea))
        LGInteractionDiagnostics.event("scroll.dismiss.prepare", "offset=\(scroll.contentOffset.y) content=\(scroll.contentSize.height) inset=\(scroll.adjustedContentInset.bottom) reserve=\(bottomSpace) pastEnd=\(amountPastEnd)")
        guard keyboardSpace > 0 else { return }
        cancelRestoration()
        restoration = OutlinerRowAnchor(scroll: scroll, editor: editor, keyboardDismissed: keyboardDismissed)
        let space = min(keyboardSpace, amountPastEnd)
        guard space > bottomSpace else { return }
        setBottomSpace(space)

        // Keep the extra range until the user scrolls back into the regular range.
        scrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let self, let scroll, scroll.isTracking || scroll.isDecelerating,
                      scroll.contentOffset.y <= self.end(of: scroll, bottomInset: bottomSafeArea) else { return }
                self.release()
            }
        }
    }

    func cancelRestoration() {
        restoration?.stop()
        restoration = nil
    }

    func continueRestoration() {
        restoration?.continueAfterKeyboardAnimation()
    }

    func releaseIfKeyboardProvidesScrollRange(in scroll: UIScrollView, bottomSafeArea: CGFloat) {
        let inset = scroll.adjustedContentInset.bottom
        guard bottomSpace > 0, inset > bottomSafeArea,
              scroll.contentOffset.y <= end(of: scroll, bottomInset: inset) else { return }
        release()
    }

    func prepareForKeyboardPresentation(in scroll: UIScrollView, bottomSafeArea: CGFloat) {
        cancelRestoration()
        guard bottomSpace > 0, scroll.contentOffset.y <= end(of: scroll, bottomInset: bottomSafeArea) else { return }
        release()
    }

    private func end(of scroll: UIScrollView, bottomInset: CGFloat) -> CGFloat {
        max(-scroll.adjustedContentInset.top, scroll.contentSize.height - bottomSpace - scroll.bounds.height + bottomInset)
    }

    private func release() {
        scrollObservation = nil
        setBottomSpace(0)
    }

    private func setBottomSpace(_ space: CGFloat) {
        LGInteractionDiagnostics.event("scroll.dismiss.reserve", "height=\(space)")
        // This tail replaces keyboard space without adjusting the visible offset.
        var transaction = Transaction()
        if #available(iOS 18, *) {
            transaction.scrollContentOffsetAdjustmentBehavior = .disabled
        }
        withTransaction(transaction) { bottomSpace = space }
    }
}

@MainActor
private final class OutlinerRowAnchor: NSObject {
    private static let editorPrefix = "field.outliner.block."
    private static let titlePrefix = "outliner.block-action."
    private weak var scroll: UIScrollView?
    private let anchors: [(String, CGFloat)]
    private let keyboardDismissed: () -> Bool
    private let initialBottomInset: CGFloat
    private let activationDeadline = CACurrentMediaTime() + 2
    private var restorationDeadline: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var scrollObservations: [NSKeyValueObservation] = []
    private var isRestoring = false

    init(scroll: UIScrollView, editor: UITextView, keyboardDismissed: @escaping () -> Bool) {
        self.scroll = scroll
        self.keyboardDismissed = keyboardDismissed
        initialBottomInset = scroll.adjustedContentInset.bottom
        let top = scroll.adjustedContentInset.top
        let bottom = scroll.bounds.height - initialBottomInset
        let positions = Self.rows(in: scroll)
        var anchors = positions
            .filter { top - 24 <= $0.value && $0.value < bottom }
            .sorted { $0.value < $1.value }.prefix(5).map { ($0.key, $0.value) }
        if let id = editor.accessibilityIdentifier, id.hasPrefix(Self.editorPrefix) {
            let y = editor.convert(editor.bounds, to: scroll).minY - scroll.contentOffset.y
            if top < y + editor.bounds.height && y < bottom {
                let blockID = String(id.dropFirst(Self.editorPrefix.count))
                anchors.removeAll { $0.0 == blockID }
                // Rich rows include controls above the editor. Capture their
                // shared marker in both editing and reading layouts.
                anchors.insert((blockID, positions[blockID] ?? y), at: 0)
            }
        }
        self.anchors = anchors
        super.init()
        LGInteractionDiagnostics.event("scroll.dismiss.anchors", "count=\(anchors.count) positions=\(anchors.map(\.1))")
        let link = CADisplayLink(target: self, selector: #selector(restore))
        link.add(to: .main, forMode: .common)
        displayLink = link
        scrollObservations = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.restore() }
            },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.restore() }
            },
            scroll.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.restore() }
            },
        ]
    }

    func stop() {
        guard let displayLink else { return }
        LGInteractionDiagnostics.event("scroll.dismiss.stop", "offset=\(scroll?.contentOffset.y ?? 0) tracking=\(scroll?.isTracking == true) decelerating=\(scroll?.isDecelerating == true)")
        displayLink.invalidate()
        self.displayLink = nil
        scrollObservations.removeAll()
    }

    func continueAfterKeyboardAnimation() { restorationDeadline = CACurrentMediaTime() + 0.6 }

    @objc private func restore() {
        let now = CACurrentMediaTime()
        guard let scroll, scroll.window != nil, !scroll.isDragging, !scroll.isDecelerating,
              now < (restorationDeadline ?? activationDeadline) else { stop(); return }
        guard !isRestoring, !scroll.isTracking, keyboardDismissed() || scroll.adjustedContentInset.bottom < initialBottomInset - 1
        else { return }
        if restorationDeadline == nil { restorationDeadline = now + 0.6 }

        let positions = Self.rows(in: scroll)
        let offset = scroll.contentOffset.y
        // The original offset belongs to a different virtual layout. Wait for a
        // captured row to remount before correcting the scroll position.
        guard let target = anchors.lazy.compactMap({ id, oldY in
            positions[id].map { offset + $0 - oldY }
        }).first else { return }
        let lower = -scroll.adjustedContentInset.top
        let upper = max(lower, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let clamped = min(max(target, lower), upper)
        if abs(clamped - offset) > 0.5 {
            LGInteractionDiagnostics.event("scroll.dismiss.restore", "offset=\(offset) target=\(target) corrected=\(clamped) upper=\(upper)")
            isRestoring = true
            defer { isRestoring = false }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: clamped), animated: false)
        }
    }

    private static func rows(in scroll: UIScrollView) -> [String: CGFloat] {
        var positions: [String: CGFloat] = [:]
        func visit(_ view: UIView) {
            guard !view.isHidden else { return }
            if let marker = view as? OutlinerScrollAnchorMarker.Marker, marker.bounds.height > 0 {
                positions[marker.blockID] = marker.convert(marker.bounds, to: scroll).minY - scroll.contentOffset.y
                return
            }
            if let id = view.accessibilityIdentifier, id.hasPrefix(titlePrefix), view.bounds.height > 0 {
                positions[String(id.dropFirst(titlePrefix.count))] = view.convert(view.bounds, to: scroll).minY - scroll.contentOffset.y
                return
            }
            for child in view.subviews { visit(child) }
        }
        visit(scroll)
        return positions
    }
}

@MainActor
private enum OutlinerEditorViewport {
    static let toolbars = NSHashTable<OutlinerEditorToolbarGuide.Probe>.weakObjects()
    static let editors = NSHashTable<FocusRetainingTextView>.weakObjects()

    static func obstruction(in window: UIWindow, intersecting caret: CGRect,
                            dockedKeyboardTop: CGFloat?) -> CGRect? {
        toolbars.allObjects.compactMap { toolbar -> CGRect? in
            guard toolbar.window === window else { return nil }
            var ancestor: UIView? = toolbar
            while let view = ancestor {
                if view.isHidden || view.alpha < 0.01 { return nil }
                ancestor = view.superview
            }
            let frame = toolbar.convert(toolbar.bounds, to: window)
            guard frame.height > 0, frame.intersects(window.bounds),
                  frame.minX < caret.maxX, frame.maxX > caret.minX else { return nil }
            guard let dockedKeyboardTop else { return frame }
            // The scroll inset can update before SwiftUI positions the toolbar.
            var target = frame
            target.origin.y = min(frame.minY, dockedKeyboardTop - frame.height
                - LGNavigationSurfacePolicy.bottomPadding(occupiesLayoutSpace: true))
            return target
        }.min { $0.minY < $1.minY }
    }
}

private final class FocusRetainingTextView: OutlinerLayoutTextView {
    var onPasteContent: ((String) -> Bool)?
    var onPasteImages: (([LGImageClipboard.Image]) -> Bool)?
    weak var scrollRetention: OutlinerScrollRetention?
    private var focusPending = false
    private var caretRevealScheduled = false
    private var isDismissingKeyboard = false
    private var previousCaretLayout: CGRect?
    private var previousEditorSize: CGSize?
    private(set) var isInsertingLineBreak = false
    private(set) var isPasting = false

    func prepareForKeyboardDismissal() {
        isDismissingKeyboard = true
        guard let window else { return }
        if let scroll = outlinerScrollView {
            scrollRetention?.preserve(scroll, editor: self, bottomSafeArea: window.safeAreaInsets.bottom) { [weak self] in
                self?.isFirstResponder != true
            }
        }
    }

    func dismissKeyboardBeforeRemovingEditor() async {
        guard let window, let scroll = outlinerScrollView, isFirstResponder else { return }
        let unobscuredInset = window.safeAreaInsets.bottom + 90
        guard resignFirstResponder() else { return }

        // The focused row is pinned by the virtual list. Let the viewport grow
        // while that row still has a stable position, then unpin it.
        let deadline = ContinuousClock.now + .milliseconds(550)
        while scroll.window != nil, scroll.adjustedContentInset.bottom > unobscuredInset,
              ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
        }
        scrollRetention?.continueRestoration()
    }

    func cancelKeyboardDismissal() {
        isDismissingKeyboard = false
        scrollRetention?.cancelRestoration()
        keyboardDidChangeFrame()
    }

    private var outlinerScrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled { return scroll }
            ancestor = view.superview
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isFirstResponder, let selection = selectedTextRange else { return }
        let caret = caretRect(for: selection.end)
        if caret != previousCaretLayout || bounds.size != previousEditorSize {
            previousCaretLayout = caret
            previousEditorSize = bounds.size
            revealCaretAfterLayout()
        }
    }

    func revealCaretAfterLayout() {
        guard isFirstResponder, !isDismissingKeyboard, !caretRevealScheduled else { return }
        caretRevealScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.caretRevealScheduled = false
            guard self.isFirstResponder, !self.isDismissingKeyboard,
                  let selection = self.selectedTextRange else { return }
            self.window?.layoutIfNeeded()
            let caret = self.caretRect(for: selection.end).insetBy(dx: -8, dy: -8)
            guard !caret.isNull, !caret.isInfinite, caret.height > 0 else { return }
            var ancestor = self.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                    let target = self.convert(caret, to: scroll)
                    let inset = scroll.adjustedContentInset
                    let viewport = scroll.bounds.inset(by: inset)
                    var bottom = viewport.maxY
                    if let window = self.window {
                        let dockedKeyboardTop = inset.bottom > window.safeAreaInsets.bottom + 1
                            ? scroll.convert(viewport, to: window).maxY : nil
                        if let obstruction = OutlinerEditorViewport.obstruction(in: window,
                            intersecting: self.convert(caret, to: window), dockedKeyboardTop: dockedKeyboardTop) {
                            let toolbar = scroll.convert(obstruction, from: window)
                            if toolbar.maxY > viewport.minY {
                                bottom = max(viewport.minY, min(bottom, toolbar.minY))
                            }
                        }
                    }
                    let delta = target.minY < viewport.minY ? target.minY - viewport.minY : max(0, target.maxY - bottom)
                    let offset = scroll.contentOffset
                    let minimum = -inset.top
                    let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    let y = min(max(offset.y + delta, minimum), maximum)
                    if abs(y - offset.y) > 0.5 {
                        scroll.setContentOffset(CGPoint(x: offset.x, y: y), animated: false)
                        LGInteractionDiagnostics.event("scroll.caret.reveal", "offset=\(offset.y) target=\(y) applied=\(scroll.contentOffset.y) caret=\(target) bottom=\(bottom) max=\(maximum)")
                    }
                }
                ancestor = view.superview
            }
        }
    }

    override func paste(_ sender: Any?) {
        let images = LGImageClipboard.images()
        if !images.isEmpty, onPasteImages?(images) == true { return }
        if let payload = LGBlockClipboard.content(before: text ?? "", selection: selectedRange),
           onPasteContent?(payload) == true { return }
        guard let text = UIPasteboard.general.string else {
            super.paste(sender)
            return
        }
        isPasting = true
        defer { isPasting = false }
        // This editor stores plain text. Insert it in the same input transaction
        // so the delegate receives an explicit paste origin, including newlines.
        insertText(text)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        let lineBreak = UIKeyCommand(input: "\r", modifierFlags: .shift,
                                     action: #selector(insertInlineLineBreak))
        lineBreak.discoverabilityTitle = "Insert Line Break"
        lineBreak.wantsPriorityOverSystemBehavior = true
        return [lineBreak] + (super.keyCommands ?? [])
    }

    @objc private func insertInlineLineBreak(_ command: UIKeyCommand) {
        isInsertingLineBreak = true
        defer { isInsertingLineBreak = false }
        if delegate?.textView?(self, shouldChangeTextIn: selectedRange, replacementText: "\n") ?? true {
            insertText("\n")
        }
    }

    func cancelPendingFocus() {
        focusPending = false
    }

    func requestFocusWhenAttached() {
        guard !isFirstResponder, !isDismissingKeyboard else {
            focusPending = false
            return
        }
        focusPending = true
        fulfillPendingFocus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        OutlinerEditorViewport.editors.add(self)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(revealCaretForKeyboardChange),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidChangeFrame),
                name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        }
        LGInteractionDiagnostics.event("editor.window", "view=\(ObjectIdentifier(self)) attached=\(window != nil) responder=\(isFirstResponder)")
        fulfillPendingFocus()
    }

    override func becomeFirstResponder() -> Bool {
        if !isFirstResponder, let scroll = outlinerScrollView, let window {
            scrollRetention?.prepareForKeyboardPresentation(in: scroll, bottomSafeArea: window.safeAreaInsets.bottom)
        }
        let result = super.becomeFirstResponder()
        LGInteractionDiagnostics.event("editor.becomeFirstResponder", "view=\(ObjectIdentifier(self)) result=\(result) attached=\(window != nil)")
        if result {
            isDismissingKeyboard = false
            revealCaretAfterLayout()
        }
        return result
    }

    @objc private func revealCaretForKeyboardChange() { revealCaretAfterLayout() }

    @objc private func keyboardDidChangeFrame() {
        // Keyboard avoidance can move the scroll viewport without changing the
        // editor's local caret or size. Reveal after the final native layout.
        if isFirstResponder, !isDismissingKeyboard, let scroll = outlinerScrollView, let window {
            scrollRetention?.releaseIfKeyboardProvidesScrollRange(in: scroll, bottomSafeArea: window.safeAreaInsets.bottom)
        }
        revealCaretAfterLayout()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        LGInteractionDiagnostics.event("editor.resignFirstResponder", "view=\(ObjectIdentifier(self)) result=\(result) attached=\(window != nil)")
        return result
    }

    private func fulfillPendingFocus() {
        guard focusPending, !isDismissingKeyboard, window != nil else { return }
        if becomeFirstResponder() {
            focusPending = false
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusPending, !self.isDismissingKeyboard, self.window != nil else { return }
            if self.becomeFirstResponder() {
                self.focusPending = false
            }
        }
    }
}
#endif
