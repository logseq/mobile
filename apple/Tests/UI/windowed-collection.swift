import Foundation
import Observation
@testable import LUIAppleBackend

private final class PresentationChange: @unchecked Sendable {
    var changed = false
}

@main struct CheckWindowedCollection {
    @MainActor static func main() async throws {
        let containers: [LUINodeKind] = [.row, .column, .box]
        for kind in containers {
            precondition(LUIPlainContainerSurfacePolicy.applies(kind: kind,
                properties: [.padding: .int(8), .width: .int(24)], styleClass: nil))
            let decorated: [LUIProperty] = [.background, .foreground, .cornerRadius, .borderWidth,
                                           .opacity, .tooltip, .margin, .maxHeight, .containerRelativeFrame]
            for property in decorated {
                precondition(!LUIPlainContainerSurfacePolicy.applies(kind: kind,
                    properties: [property: .int(1)], styleClass: nil),
                    "Decorated containers must retain their complete surface behavior")
            }
        }
        precondition(!LUIPlainContainerSurfacePolicy.applies(kind: .button, properties: [:], styleClass: nil))
        precondition(!LUIPlainContainerSurfacePolicy.applies(kind: .column, properties: [:], styleClass: "composer-surface"))
        precondition(!LUIPlainContainerSurfacePolicy.applies(kind: .box, properties: [:], styleClass: "body-line"))
        let presentationBackend = LUIAppleBackend()
        try presentationBackend.apply(json: #"{"generation":1,"ops":[{"op":"create-node","id":1,"kind":"column"}]}"#)
        let previewChange = PresentationChange()
        let sheetsChange = PresentationChange()
        withObservationTracking {
            _ = presentationBackend.filePreviewPresentation.item
        } onChange: { previewChange.changed = true }
        withObservationTracking {
            _ = presentationBackend.modalPresentation.nestedSheets
        } onChange: { sheetsChange.changed = true }
        try presentationBackend.apply(json: #"{"generation":2,"ops":[{"op":"create-node","id":2,"kind":"text"},{"op":"insert-child","parent":1,"child":2,"index":0}]}"#)
        precondition(!previewChange.changed,
                     "Replacing page rows must not invalidate an unchanged file preview")
        precondition(!sheetsChange.changed,
                     "Replacing page rows must not invalidate unchanged nested sheets")

        let preview = LUIFilePreviewStore()
        let first = LUIFilePreviewPresentation(nodeID: 10, rootID: 1, url: URL(fileURLWithPath: "/tmp/first.pdf"))
        preview.synchronize(with: first)
        let unchangedPreview = PresentationChange()
        withObservationTracking { _ = preview.item } onChange: { unchangedPreview.changed = true }
        preview.synchronize(with: first)
        precondition(!unchangedPreview.changed, "An unchanged presented preview must not invalidate the root")
        preview.synchronize(with: LUIFilePreviewPresentation(nodeID: 10, rootID: 1, url: URL(fileURLWithPath: "/tmp/second.pdf")))
        precondition(unchangedPreview.changed && preview.item?.url.lastPathComponent == "second.pdf",
                     "Changing the preview URL must still update the presentation")
        precondition(preview.dismissFromPresentation() == 10)
        preview.synchronize(with: first)
        precondition(preview.item == nil, "Interactive dismissal must suppress the retained preview")
        preview.synchronize(with: nil)
        preview.synchronize(with: first)
        precondition(preview.item?.nodeID == 10, "A preview may reopen after its wire node was removed")

        let backend = LUIAppleBackend()
        try backend.apply(json: #"{"generation":1,"ops":[{"op":"create-node","id":1,"kind":"list"},{"op":"set-prop","id":1,"property":"data-attrs","value":"data-virtual-count\u001f10000\u001edata-virtual-start\u001f0"}]}"#)
        backend.coalescesCommits = true
        try backend.apply(json: #"{"generation":2,"ops":[{"op":"set-prop","id":1,"property":"data-attrs","value":"data-virtual-count\u001f10000\u001edata-virtual-start\u001f9000"}]}"#)
        precondition(backend.model(id: 1)?.property(.dataAttrs)?.stringValue?.contains("9000") == true,
                     "Visible row replacement must not wait for the generic commit debounce")
        print("PASS: plain surfaces, stable presentations, immediate window commits")
    }
}
