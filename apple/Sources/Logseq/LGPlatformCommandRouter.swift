import Foundation
import LogseqModel
#if os(iOS)
import UIKit
#endif

public enum LGPlatformPresentation: Equatable, Sendable {
    case confirmDelete(blockIDs: [String])
    case pickAttachment(blockID: String?)
    case takePhoto(blockID: String?)
    case recordAudio(blockID: String?)
    case focusBlock(blockID: String?)
}

@MainActor
public final class LGPlatformCommandRouter: LGPlatformCommandHandling {
    private let setClipboardText: (String) -> Void
    private let performHaptic: (String?) -> Void
    private let present: (LGPlatformPresentation) -> Void
    #if os(iOS)
    private var clipboardTask: Task<Void, Never>?
    #endif

    public init(
        setClipboardText: @escaping (String) -> Void,
        performHaptic: @escaping (String?) -> Void,
        present: @escaping (LGPlatformPresentation) -> Void
    ) {
        self.setClipboardText = setClipboardText
        self.performHaptic = performHaptic
        self.present = present
    }

    public func handle(_ batch: LGPlatformCommandBatch) {
        for command in batch.commands {
            #if os(iOS)
            if command.type.hasPrefix("setClipboard") { clipboardTask?.cancel() }
            #endif
            switch command.type {
            case "haptic":
                performHaptic(command.style)
            case "confirmDelete":
                present(.confirmDelete(blockIDs: command.uuids ?? []))
            case "setClipboardText":
                setClipboardText(command.text ?? "")
            case "setClipboardBlocks":
                _ = LGBlockClipboard.write(command.text ?? "")
            #if os(iOS)
            case "setClipboardImages":
                if let images = command.imageClipboard { copyImages(images) }
            #endif
            case "setClipboardReferences":
                setClipboardText(Self.nodeReferences(command.uuids ?? []))
            case "setClipboardURLs":
                setClipboardText(Self.blockURLs(
                    graphName: batch.graphName ?? "",
                    blockIDs: command.uuids ?? []
                ))
            case "pickAttachment":
                present(.pickAttachment(blockID: command.uuid))
            case "takePhoto":
                present(.takePhoto(blockID: command.uuid))
            case "recordAudio":
                present(.recordAudio(blockID: command.uuid))
            case "focusBlock":
                present(.focusBlock(blockID: command.uuid))
            default:
                break
            }
        }
    }

    #if os(iOS)
    private func copyImages(_ clipboard: LogseqOutlinerCommand.ImageClipboard) {
        let changeCount = UIPasteboard.general.changeCount
        clipboardTask = Task {
            do {
                var urls: [URL] = []
                for image in clipboard.images {
                    urls.append(try await LGGraphAssetLoader.load(uuid: image.uuid, assetType: image.assetType,
                        expectedGraphId: clipboard.graphId, feedbackTitle: String(localized: "Image", bundle: .module)))
                    try Task.checkCancellation()
                }
                try await LGImageClipboard.write(urls, replacing: changeCount)
            } catch is CancellationError {
                return
            } catch {
                LogseqRuntimeLog.shared.append(level: .error, source: .ui, message: error.localizedDescription)
            }
        }
    }
    #endif

    private static func nodeReferences(_ blockIDs: [String]) -> String {
        blockIDs.map { "[[\($0)]]" }.joined(separator: "\n")
    }

    private static func blockURLs(graphName: String, blockIDs: [String]) -> String {
        blockIDs.map {
            SharedDeepLink.blockURL(graphName: graphName, blockID: $0)
        }.joined(separator: "\n")
    }
}
