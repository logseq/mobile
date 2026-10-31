#if os(iOS)
import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct LGMediaPanel: View {
    let initialService: LGAttachmentService
    let onPhotos: ([PhotosPickerItem]) -> Void
    let onCapture: (Data) -> Void
    let onPhotoData: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: LGAttachmentService
    @State private var selection: [PhotosPickerItem] = []
    @State private var allPhotos = false
    @State private var importError: String?
    @State private var selectedPhotos: [PHPickerResult] = []
    @State private var importedPhotoIDs: Set<String> = []
    @State private var isImporting = false

    init(initialService: LGAttachmentService,
         onPhotos: @escaping ([PhotosPickerItem]) -> Void,
         onCapture: @escaping (Data) -> Void,
         onPhotoData: @escaping (Data, String) -> Void) {
        self.initialService = initialService
        self.onPhotos = onPhotos
        self.onCapture = onCapture
        self.onPhotoData = onPhotoData
        _mode = State(initialValue: initialService)
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .camera {
                LGInlineCamera { data in
                    onCapture(data)
                    dismiss()
                }
                    .overlay(alignment: .bottom) {
                        controls
                    }
            } else {
                LGEmbeddedPhotos(importedIDs: importedPhotoIDs) { results in
                    selectedPhotos = results.filter {
                        !importedPhotoIDs.contains($0.assetIdentifier ?? "")
                    }
                }
                .disabled(isImporting)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controls.background(Color(uiColor: .systemBackground))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Photo import failed", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            onPhotos(items)
            selection = []
            dismiss()
        }
    }

    private var controls: some View {
        HStack {
            Button { dismiss() } label: {
                controlIcon("chevron.left")
            }
            .accessibilityLabel("Back to Capture")
            Spacer()
            if mode == .photos {
                if selectedPhotos.isEmpty {
                    Button { allPhotos = true } label: {
                        Text("All Photos")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(Color(uiColor: .label), in: Capsule())
                    }
                    .photosPicker(isPresented: $allPhotos, selection: $selection,
                                  maxSelectionCount: 20, selectionBehavior: .ordered,
                                  matching: .images)
                } else {
                    Button(action: addSelectedPhotos) {
                        HStack(spacing: 8) {
                            if isImporting { ProgressView().tint(.white) }
                            Text(selectedPhotos.count == 1 ? "Add 1 item" : "Add \(selectedPhotos.count) items")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(Color.blue, in: Capsule())
                    }
                    .disabled(isImporting)
                    .accessibilityIdentifier("media.add-selected")
                }
            }
            if mode == .camera || selectedPhotos.isEmpty {
                Menu {
                    Button("Camera", systemImage: "camera") { mode = .camera }
                    Button("Photos", systemImage: "photo.on.rectangle") { mode = .photos }
                } label: {
                    controlIcon("ellipsis")
                }
                .accessibilityLabel("Attachment source")
            }
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .frame(height: mode == .camera ? 64 : 44)
        .padding(.horizontal, 20)
        .padding(.vertical, mode == .camera ? 20 : 12)
    }

    private func addSelectedPhotos() {
        guard !isImporting, !selectedPhotos.isEmpty else { return }
        isImporting = true
        let photos = selectedPhotos
        Task { @MainActor in
            for photo in photos {
                do {
                    let provider = photo.itemProvider
                    guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                        .first(where: { $0.conforms(to: .image) }) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                        }
                    }
                    let imageType = CGImageSourceCreateWithData(data as CFData, nil)
                        .flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
                    onPhotoData(data, imageType?.preferredFilenameExtension
                                ?? type.preferredFilenameExtension ?? "jpg")
                    if let id = photo.assetIdentifier { importedPhotoIDs.insert(id) }
                    selectedPhotos.removeAll { $0.assetIdentifier == photo.assetIdentifier }
                } catch {
                    importError = error.localizedDescription
                    isImporting = false
                    return
                }
            }
            isImporting = false
            dismiss()
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(mode == .camera ? Color.white : Color.primary)
            .frame(width: 44, height: 44)
            .background {
                Circle().fill(mode == .camera
                              ? Color.black.opacity(0.35)
                              : Color(uiColor: .secondarySystemBackground))
            }
    }

}

// Isolate the embedded picker from the surrounding SwiftUI sheet's presentation traits.
private struct LGEmbeddedPhotos: UIViewControllerRepresentable {
    let importedIDs: Set<String>
    let onSelection: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> Container {
        Container(onSelection: onSelection)
    }

    func updateUIViewController(_ controller: Container, context: Context) {
        controller.deselectImported(importedIDs)
    }

    final class Container: UIViewController, PHPickerViewControllerDelegate {
        let onSelection: ([PHPickerResult]) -> Void
        private var picker: PHPickerViewController?
        private var importedIDs: Set<String> = []

        init(onSelection: @escaping ([PHPickerResult]) -> Void) {
            self.onSelection = onSelection
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidLoad() {
            super.viewDidLoad()
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.filter = .images
            configuration.selectionLimit = 20
            configuration.selection = .continuousAndOrdered
            configuration.edgesWithoutContentMargins = .all
            configuration.disabledCapabilities = [.selectionActions]
            let picker = PHPickerViewController(configuration: configuration)
            self.picker = picker
            picker.delegate = self
            addChild(picker)
            picker.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(picker.view)
            NSLayoutConstraint.activate([
                picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                picker.view.topAnchor.constraint(equalTo: view.topAnchor),
                picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            picker.didMove(toParent: self)
            picker.zoomIn()
        }

        func deselectImported(_ identifiers: Set<String>) {
            let added = identifiers.subtracting(importedIDs)
            importedIDs = identifiers
            if !added.isEmpty { picker?.deselectAssets(withIdentifiers: Array(added)) }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelection(results)
        }
    }
}

// All capture configuration and start/stop operations are serialized off the main thread.
private final class LGCameraSession: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.logseq.logseq.capture")
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var capturing = false
    var onPhoto: (@MainActor @Sendable (Data?, String?) -> Void)?

    func start(completion: @escaping @MainActor @Sendable (String?) -> Void) {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    Task { @MainActor in completion("Camera is unavailable.") }
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.output)
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            Task { @MainActor in completion(nil) }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture() {
        queue.async {
            guard self.session.isRunning, !self.capturing else { return }
            self.capturing = true
            if let connection = self.output.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let message = error?.localizedDescription ?? (data == nil ? "Unable to capture photo." : nil)
        Task { @MainActor in self.onPhoto?(data, message) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        queue.async { self.capturing = false }
        if let error {
            Task { @MainActor in self.onPhoto?(nil, error.localizedDescription) }
        }
    }
}

private struct LGInlineCamera: View {
    let onCapture: (Data) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = LGCameraSession()
    @State private var errorMessage: String?
    @State private var permissionDenied = false
    @State private var visible = false
    @State private var ready = false
    @State private var capturing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LGCameraPreview(session: camera.session)
                .background(.black)
                .clipped()
            if permissionDenied {
                VStack(spacing: 12) {
                    Text("Allow camera access in Settings to take photos.").multilineTextAlignment(.center)
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                .padding(24)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                capturing = true
                camera.capture()
            } label: {
                Circle().fill(.white)
                    .padding(5)
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
                    .frame(width: 64, height: 64)
            }
            .accessibilityLabel("Take photo")
            .disabled(!ready || capturing)
            .opacity(ready && !capturing ? 1 : 0.5)
            .padding(.bottom, 20)
        }
        .onChange(of: errorMessage) { _, message in
            if let message { logger.error(message) }
        }
        .task { visible = true; await start() }
        .onDisappear { visible = false; camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await start() }
            } else {
                ready = false
                camera.stop()
            }
        }
    }

    private func start() async {
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard visible, scenePhase == .active, !Task.isCancelled else { return }
        permissionDenied = !allowed
        guard allowed else {
            errorMessage = "Allow camera access in Settings to take photos."
            return
        }
        let busy = $capturing
        let failure = $errorMessage
        let capture = onCapture
        camera.onPhoto = { data, message in
            busy.wrappedValue = false
            failure.wrappedValue = message
            if let data { capture(data) }
        }
        camera.start { message in
            errorMessage = message
            ready = message == nil
        }
    }
}

private struct LGCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
#endif
