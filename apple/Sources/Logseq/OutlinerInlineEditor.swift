import SwiftUI
#if os(iOS)
import UIKit
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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = FocusRetainingTextView()
        textView.delegate = context.coordinator
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
        if focusEnabled { textView.requestFocusWhenAttached() }
        LGInteractionDiagnostics.editor(textView, blockID: blockID, event: "editor.make")
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
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
    }

    private func applyTextLayout(to textView: UITextView) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let inset = OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: font.lineHeight,
            minimumLineHeight: OutlinerLayoutMetrics.titleLineHeight
        )
        textView.font = font
        textView.textContainerInset = UIEdgeInsets(
            top: inset,
            left: 0,
            bottom: inset,
            right: 0
        )
    }

    private func applyWritingAssistance(to textView: UITextView) {
        let defaults = UserDefaults.standard
        let spellCheck = defaults.object(forKey: "logseq.editor.spellCheck") as? Bool ?? true
        let autoCorrection = defaults.object(forKey: "logseq.editor.autoCorrection") as? Bool ?? true
        textView.spellCheckingType = spellCheck ? .yes : .no
        textView.autocorrectionType = autoCorrection ? .yes : .no
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let font = uiView.font else { return nil }
        return OutlinerNativeTextMeasurement.size(
            text: uiView.text,
            font: font,
            width: width,
            verticalInset: uiView.textContainerInset.top,
            scale: uiView.traitCollection.displayScale
        )
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

        init(parent: NativeOutlinerTextView) {
            self.parent = parent
            activeBlockID = parent.blockID
            selectionRevision = parent.selectionRevision
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
            LGInteractionDiagnostics.editor(textView, blockID: activeBlockID, event: "editor.input")
            localText = textView.text
            guard textView.markedTextRange == nil else { return }
            if (textView as? FocusRetainingTextView)?.isPasting == true, let onPaste = parent.onPaste {
                onPaste(textView.text, textView.selectedRange.location)
            } else {
                parent.onTextChange(textView.text, textView.selectedRange.location)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
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
            let isInlineLineBreak = (textView as? FocusRetainingTextView)?.isInsertingLineBreak == true
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
            if replacement == "\n", NativeEditorInputPolicy.allowsLineBreak(parent.inputPolicy) { return true }
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

private final class FocusRetainingTextView: OutlinerLayoutTextView {
    var onPasteContent: ((String) -> Bool)?
    private var focusPending = false
    private(set) var isInsertingLineBreak = false
    private(set) var isPasting = false

    override func paste(_ sender: Any?) {
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
        guard !isFirstResponder else {
            focusPending = false
            return
        }
        focusPending = true
        fulfillPendingFocus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        LGInteractionDiagnostics.event("editor.window", "view=\(ObjectIdentifier(self)) attached=\(window != nil) responder=\(isFirstResponder)")
        fulfillPendingFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        LGInteractionDiagnostics.event("editor.becomeFirstResponder", "view=\(ObjectIdentifier(self)) result=\(result) attached=\(window != nil)")
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        LGInteractionDiagnostics.event("editor.resignFirstResponder", "view=\(ObjectIdentifier(self)) result=\(result) attached=\(window != nil)")
        return result
    }

    private func fulfillPendingFocus() {
        guard focusPending, window != nil else { return }
        if becomeFirstResponder() {
            focusPending = false
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusPending, self.window != nil else { return }
            if self.becomeFirstResponder() {
                self.focusPending = false
            }
        }
    }
}
#endif
