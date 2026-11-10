import Foundation
import SwiftUI

#if os(iOS)
import AVKit
import UIKit
#endif

enum AssetPresentationKind: Equatable {
    case image
    case audio
    case file
}

enum AssetPresentationPolicy {
    static func kind(assetType: String?, localPath: String?) -> AssetPresentationKind {
        let normalizedType = (assetType ?? pathExtension(localPath)).lowercased()
        if normalizedType.hasPrefix("image/")
            || ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "bmp", "wbmp"].contains(normalizedType) {
            return .image
        }
        if normalizedType.hasPrefix("audio/")
            || ["m4a", "mp3", "wav", "aac", "caf"].contains(normalizedType) {
            return .audio
        }
        return .file
    }

    private static func pathExtension(_ path: String?) -> String {
        guard let fileName = path?.split(separator: "/").last else { return "" }
        let components = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count > 1 else { return "" }
        return String(components.last ?? "")
    }
}

#if os(iOS)
struct AssetAudioPlayer: View {
    @State private var player: AVPlayer
    @State private var isPlaying = false

    init(path: String) {
        _player = State(initialValue: AVPlayer(url: URL(fileURLWithPath: path)))
    }

    var body: some View {
        Button {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20, height: 20)
                Text(verbatim: isPlaying ? "Pause audio" : "Play audio")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.asset.audio")
        .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")
        .onDisappear {
            player.pause()
            isPlaying = false
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#endif

struct IconImage: View {
    let name: String
    let size: CGFloat

    init(name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    private static let assetBundle: Bundle = {
        return Bundle.module
    }()

    var body: some View {
        Image(name, bundle: Self.assetBundle)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
