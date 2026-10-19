import Foundation
import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq

@main struct CheckAttachmentPresentation {
    @MainActor static func main() async throws {
        let coordinator = LGPlatformPresentationCoordinator()
        let store = LogseqStore(call: { _ in fatalError("Presentation checks must not dispatch core requests") })
        var staged: [String] = []
        let host = LGPlatformPresentationHost(coordinator: coordinator, store: store, stageAsset: { staged.append($0) })
        var errors: [String] = []
        for (old, next) in [("files", "camera"), ("camera", "files"), ("files", "files"), ("camera", "camera")] {
            coordinator.completeAttachment()
            coordinator.presentAttachment(old, targetBlockID: "old")
            let binding = old == "camera" ? host.mediaPanelBinding : host.presentationBinding(for: .files)
            coordinator.presentAttachment(next, targetBlockID: "next")
            binding.wrappedValue = false
            if coordinator.attachmentService?.rawValue != next || coordinator.attachmentTargetBlockID != "next" {
                errors.append("A stale \(old) dismissal cancelled the newer \(next) request")
            }
        }
        coordinator.completeAttachment()
        coordinator.presentAttachment("files", targetBlockID: "live")
        host.presentationBinding(for: .audio).wrappedValue = false
        if coordinator.attachmentService != .files { errors.append("An inactive audio binding cancelled the file picker") }
        let id = coordinator.attachmentRequestID
        if coordinator.presentAttachment("invalid") || coordinator.attachmentRequestID != id { errors.append("An invalid service changed the current request") }
        coordinator.completeAttachment()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("attachment".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        coordinator.presentAttachment("files", targetBlockID: "file-target")
        host.importFiles(.success([source]))
        coordinator.presentAttachment("camera", targetBlockID: "camera-target")
        for _ in 0..<100 {
            if !staged.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(20))
        if staged.isEmpty { errors.append("The existing file import was lost") }
        if coordinator.attachmentService != .camera || coordinator.attachmentTargetBlockID != "camera-target" {
            errors.append("Finishing a file import cancelled the newer camera request")
        }
        if let encoded = staged.first {
            let json = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
            if json["targetBlockId"] as? String != "file-target" { errors.append("The imported file moved to a newer request's block") }
            if let path = json["localPath"] as? String, let resolved = LocalAssetPath.resolve(path) {
                try? FileManager.default.removeItem(at: resolved)
            }
        }
        guard errors.isEmpty else { throw NSError(domain: "AttachmentPresentationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "; ")]) }
        coordinator.completeAttachment()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: Text("Attachment presentation check").modifier(host))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let field = UITextField(frame: CGRect(x: 20, y: 100, width: 250, height: 40))
        field.text = "Capture"
        controller.view.addSubview(field)
        field.becomeFirstResponder()
        for service in ["files", "camera", "files"] {
            coordinator.presentAttachment(service)
            for _ in 0..<80 {
                if let presented = controller.presentedViewController,
                   !presented.isBeingPresented && !presented.isBeingDismissed { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let presented = controller.presentedViewController else {
                throw NSError(domain: "AttachmentPresentationCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: service + " did not present after keyboard interaction"])
            }
            if service == "files" {
                precondition(presented is UIDocumentPickerViewController, "File must open the system document picker")
            }
            precondition(coordinator.attachmentService?.rawValue == service, "A presentation must retain its own active request")
            print("PICKER_UI service=\(service) controller=\(type(of: presented))")
            coordinator.completeAttachment()
            for _ in 0..<80 {
                if controller.presentedViewController == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(controller.presentedViewController == nil, "A dismissed picker must allow the next picker to open")
        }
        print("PASS: keyboard-active File/Camera/File presentation and stale picker callbacks")
    }
}
