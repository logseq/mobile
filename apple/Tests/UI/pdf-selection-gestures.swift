import PDFKit
import UIKit
@testable import Logseq

@main struct PDFSelectionGesturesCheck {
    @MainActor static func main() async throws {
        let reader = LGPDFSelectionView()
        let native = PDFView()
        let scrolling = UIPanGestureRecognizer()
        let selecting = UILongPressGestureRecognizer()
        let readerDelegate: UIGestureRecognizerDelegate = reader
        let nativeDelegate: UIGestureRecognizerDelegate = native
        // UIKit asks PDFKit about its own gesture pairs when text is touched.
        for (first, second) in [(scrolling, selecting), (selecting, scrolling)] {
            let expected = nativeDelegate.gestureRecognizer?(first, shouldRecognizeSimultaneouslyWith: second)
            let actual = readerDelegate.gestureRecognizer?(first, shouldRecognizeSimultaneouslyWith: second)
            guard actual == expected else { throw failure("Native PDFKit gesture arbitration must remain unchanged") }
        }
        guard let pencil = reader.gestureRecognizers?.first(where: { $0.name == "pdf.pencil-select" }),
              let annotation = reader.gestureRecognizers?.first(where: { $0.name == "pdf.annotation-tap" }) else {
            throw failure("Missing custom PDF interactions")
        }
        for gesture in [scrolling, selecting] {
            guard pencil.delegate?.gestureRecognizer?(pencil, shouldRecognizeSimultaneouslyWith: gesture) == false,
                  annotation.delegate?.gestureRecognizer?(annotation, shouldRecognizeSimultaneouslyWith: gesture) == true else {
                throw failure("Pencil selection must be exclusive while annotation taps coexist with PDFKit")
            }
        }
        // UIKit stores recognizer delegates weakly; the reader must keep them alive.
        try await Task.sleep(for: .milliseconds(100))
        guard pencil.delegate != nil, annotation.delegate != nil else { throw failure("Gesture delegates were released") }
        print("PASS: PDF text gestures preserve native optional delegate behavior and custom gesture arbitration")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PDFSelectionGestures", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
