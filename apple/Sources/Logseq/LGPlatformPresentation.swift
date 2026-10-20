import Observation
import SwiftUI
import LogseqModel

import CryptoKit
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import QuickLook
import UIKit
#endif

public enum LGAttachmentService: String, CaseIterable, Sendable {
    case files
    case camera
    case photos
    case audio
}

struct LGAttachmentRequest {
    let id: UUID
    let targetBlockID: String?
}

@MainActor
@Observable
public final class LGPlatformPresentationCoordinator {
    public var journalCalendarPresented = false
    public var graphDownloadProgress: LogseqGraphDownloadProgress?
    public private(set) var attachmentService: LGAttachmentService?
    public private(set) var attachmentTargetBlockID: String?
    public private(set) var attachmentRequestID = UUID()

    var attachmentRequest: LGAttachmentRequest {
        LGAttachmentRequest(id: attachmentRequestID, targetBlockID: attachmentTargetBlockID)
    }
    public private(set) var pendingDeletionBlockIDs: [String] = []

    public init() {
    }

    @discardableResult
    public func presentJournalCalendar() -> Bool {
        journalCalendarPresented = true
        return true
    }

    @discardableResult
    public func presentAttachment(
        _ rawValue: String,
        targetBlockID: String? = nil
    ) -> Bool {
        guard let service = LGAttachmentService(rawValue: rawValue) else {
            return false
        }
        attachmentRequestID = UUID()
        attachmentService = service
        attachmentTargetBlockID = targetBlockID
        return true
    }

    public func dismissAttachment(requestID: UUID? = nil) {
        guard requestID == nil || requestID == attachmentRequestID else { return }
        attachmentService = nil
    }

    public func completeAttachment(requestID: UUID? = nil) {
        guard requestID == nil || requestID == attachmentRequestID else { return }
        attachmentService = nil
        attachmentTargetBlockID = nil
    }

    public func confirmDeletion(of blockIDs: [String]) {
        pendingDeletionBlockIDs = blockIDs
    }

    public func dismissDeletion() {
        pendingDeletionBlockIDs = []
    }

    #if os(iOS)
    @discardableResult
    public func presentPageShare(_ payload: LGPageSharePayload) -> Bool {
        return presentShareSheet(
            NodeSharePayload(
                text: payload.text,
                localAssetPaths: payload.localAssetPaths
            ).items
        )
    }

    @discardableResult
    public func presentFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return presentShareSheet([url])
    }

    /// Presents the activity sheet on the topmost presented controller so it
    /// can appear above an already-presented LUI sheet (e.g. Settings); a
    /// root-level `.sheet` would queue behind it with no visible feedback.
    private func presentShareSheet(_ items: [Any]) -> Bool {
        guard let presenter = Self.topmostPresenter() else { return false }
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
        }
        presenter.present(controller, animated: true)
        return true
    }

    private static func topmostPresenter() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        let root = windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windows.first?.rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    #endif
}


#if os(iOS)
struct LGJournalCalendar: View {
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var selected = false

    var body: some View {
        NavigationStack {
            DatePicker("Choose a date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 16)
                .accessibilityIdentifier("picker.journal-date")
                .onChange(of: date) { _, value in select(value) }
                .navigationTitle("Go to journal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Today") { select(Date()) }
                            .accessibilityIdentifier("button.journal-calendar.today")
                    }
                }
        }
    }

    private func select(_ date: Date) {
        guard !selected else { return }
        selected = true
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        onSelect(parts.year! * 10000 + parts.month! * 100 + parts.day!)
    }
}
#endif

struct LGImportedAsset: Sendable {
    let title: String
    let assetType: String
    let size: Int
    let checksum: String
    let path: String
}

enum LGAssetImporter {
    nonisolated static func persist(_ sourceURL: URL) async throws -> LGImportedAsset {
        try await Task.detached(priority: .utility) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(
                UUID().uuidString + "-" + sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return LGImportedAsset(
                title: sourceURL.lastPathComponent,
                assetType: destination.pathExtension.lowercased(),
                size: size,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }

    nonisolated static func persist(
        data: Data,
        title: String
    ) async throws -> LGImportedAsset {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(title)
            try data.write(to: destination, options: .atomic)
            let checksum = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return LGImportedAsset(
                title: title,
                assetType: destination.pathExtension.lowercased(),
                size: data.count,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }
}

struct LGPlatformPresentationHost: ViewModifier {
    @Bindable var coordinator: LGPlatformPresentationCoordinator
    let confirmOutlinerDelete: @MainActor () -> Void
    let stageAsset: @MainActor (String) throws -> Void
    var openJournal: @MainActor (Int) async throws -> Void = { _ in }
    @State private var journalError: String?

    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        let request = coordinator.attachmentRequest
        return content
            .fileImporter(
                isPresented: presentationBinding(for: .files),
                allowedContentTypes: [.image, .audio, .data],
                allowsMultipleSelection: true,
                onCompletion: { importFiles($0, request: request) }
            )
            #if !os(iOS)
            .photosPicker(
                isPresented: presentationBinding(for: .photos),
                selection: $selectedPhotoItems,
                maxSelectionCount: 20,
                matching: .images
            )
            .onChange(of: selectedPhotoItems) { _, items in
                importPhotos(items)
            }
            #endif
            .alert(deletionTitle, isPresented: deletionBinding) {
                Button("Delete", role: .destructive) {
                    confirmOutlinerDelete()
                    coordinator.dismissDeletion()
                }
                Button("Cancel", role: .cancel) {
                    coordinator.dismissDeletion()
                }
            } message: {
                Text("This deletes the block and all of its children. Pages use Recycle instead.")
            }
            #if os(iOS)
            .sheet(item: Binding(
                get: { coordinator.graphDownloadProgress },
                set: { _ in }
            )) { _ in
                GraphDownloadProgressView(coordinator: coordinator)
                    .presentationDetents([.height(260)])
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $coordinator.journalCalendarPresented) {
                LGJournalCalendar { day in
                    coordinator.journalCalendarPresented = false
                    Task {
                        do { try await openJournal(day) }
                        catch { journalError = error.localizedDescription }
                    }
                }
                .presentationDetents([.height(460)])
            }
            .alert("Could not open journal", isPresented: Binding(
                get: { journalError != nil }, set: { if !$0 { journalError = nil } }
            )) {
                Button("OK") { journalError = nil }
            } message: { Text(journalError ?? "") }
            .sheet(isPresented: mediaPanelBinding) {
                let request = coordinator.attachmentRequest
                let target = request.targetBlockID
                VStack(spacing: 0) {
                    LGMediaPanel(initialService: coordinator.attachmentService ?? .photos) { items in
                        importPhotos(items, closeWhenFinished: false, request: request)
                    } onCapture: { data in
                        importCapturedData(data, targetBlockID: target)
                    } onPhotoData: { data, fileExtension in
                        importCapturedData(data, targetBlockID: target,
                                           title: "Photo-\(UUID().uuidString).\(fileExtension)")
                    }
                }
                .background(Color(uiColor: .systemBackground))
                .presentationDetents([.fraction(0.58), .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(32)
            }
            .sheet(isPresented: presentationBinding(for: .audio)) {
                let request = coordinator.attachmentRequest
                AudioRecorderSheet(
                    targetBlockID: request.targetBlockID
                ) { asset, targetBlockID, transcript in
                    try addImportedAsset(LGImportedAsset(
                        title: asset.title, assetType: AudioRecordingPolicy.fileExtension,
                        size: asset.size, checksum: asset.checksum, path: asset.path
                    ), targetBlockID: targetBlockID, transcript: transcript)
                    coordinator.completeAttachment(requestID: request.id)
                }
            }
            #endif
    }

    var mediaPanelBinding: Binding<Bool> {
        let request = coordinator.attachmentRequest
        return Binding(
            get: {
                coordinator.attachmentRequestID == request.id &&
                    (coordinator.attachmentService == .camera || coordinator.attachmentService == .photos)
            },
            set: { shown in
                if !shown, coordinator.attachmentService == .camera || coordinator.attachmentService == .photos {
                    coordinator.completeAttachment(requestID: request.id)
                }
            }
        )
    }

    func presentationBinding(for service: LGAttachmentService) -> Binding<Bool> {
        let request = coordinator.attachmentRequest
        return Binding(
            get: { coordinator.attachmentRequestID == request.id && coordinator.attachmentService == service },
            set: { shown in
                if !shown, coordinator.attachmentService == service {
                    coordinator.dismissAttachment(requestID: request.id)
                }
            }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { !coordinator.pendingDeletionBlockIDs.isEmpty },
            set: { presented in
                if !presented {
                    coordinator.dismissDeletion()
                }
            }
        )
    }


    private var deletionTitle: String {
        coordinator.pendingDeletionBlockIDs.count > 1 ? "Delete blocks?" : "Delete block?"
    }

    func importFiles(_ result: Result<[URL], Error>, request: LGAttachmentRequest? = nil) {
        let request = request ?? coordinator.attachmentRequest
        guard case .success(let urls) = result else {
            coordinator.completeAttachment(requestID: request.id)
            return
        }
        Task {
            for url in urls {
                do {
                    try addImportedAsset(try await LGAssetImporter.persist(url), targetBlockID: request.targetBlockID)
                } catch {
                    logger.error("Asset import failed: \(String(describing: error))")
                }
            }
            coordinator.completeAttachment(requestID: request.id)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem], closeWhenFinished: Bool = true,
                              request: LGAttachmentRequest? = nil) {
        guard !items.isEmpty else { return }
        selectedPhotoItems = []
        let request = request ?? coordinator.attachmentRequest
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let title = "Photo-\(UUID().uuidString).\(fileExtension)"
                    try addImportedAsset(
                        try await LGAssetImporter.persist(data: data, title: title),
                        targetBlockID: request.targetBlockID
                    )
                } catch {
                    logger.error("Photo import failed: \(String(describing: error))")
                }
            }
            if closeWhenFinished { coordinator.completeAttachment(requestID: request.id) }
        }
    }

    #if os(iOS)
    private func importCapturedData(_ data: Data, targetBlockID: String?,
                                    title: String = "Camera-\(UUID().uuidString).jpg") {
        Task {
            do {
                try addImportedAsset(
                    try await LGAssetImporter.persist(data: data, title: title),
                    targetBlockID: targetBlockID
                )
            } catch {
                logger.error("Camera import failed: \(String(describing: error))")
            }
        }
    }
    #endif

    private func addImportedAsset(_ asset: LGImportedAsset, targetBlockID: String? = nil, transcript: String? = nil) throws {
        let payload = LGStagedAssetPayload(
            uuid: UUID().uuidString.lowercased(), title: asset.title,
            now: Int64(Date().timeIntervalSince1970 * 1_000),
            assetType: asset.assetType, assetSize: asset.size,
            assetChecksum: asset.checksum,
            localPath: LocalAssetPath.storedPath(asset.path),
            targetBlockId: targetBlockID,
            transcript: transcript, transcriptUUID: transcript == nil ? nil : UUID().uuidString.lowercased()
        )
        let data = try JSONEncoder().encode(payload)
        try stageAsset(String(decoding: data, as: UTF8.self))
    }
}

private struct LGStagedAssetPayload: Encodable {
    let uuid: String
    let title: String
    let now: Int64
    let assetType: String
    let assetSize: Int
    let assetChecksum: String
    let localPath: String
    let targetBlockId: String?
    let transcript: String?
    let transcriptUUID: String?
}
