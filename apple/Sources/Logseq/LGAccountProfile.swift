import ImageIO
import LogseqModel
import PhotosUI
import SwiftUI
import UIKit

@MainActor @Observable final class AccountProfilePresentation {
    static let shared = AccountProfilePresentation()
    var isPresented = false
}

struct LGAccountProfile: View {
    let readProfile: () async throws -> LogseqAccountProfile
    let updateProfile: (String, Data?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var originalName = ""
    @State private var photoURL: URL?
    @State private var originalPhoto: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var photo: Data?
    @State private var loading = true
    @State private var saving = false
    @State private var processingPhoto = false
    @State private var failedToLoad = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    ProgressView()
                } else if failedToLoad {
                    Button(String(localized: "Try Again", bundle: .module)) { Task { await load() } }
                } else {
                    Section {
                        Button { showingPhotoPicker = true } label: {
                            HStack(spacing: 12) {
                                avatar
                                Text(String(localized: "Change Photo", bundle: .module))
                                if processingPhoto {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        TextField(String(localized: "Full Name", bundle: .module), text: $name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("field.account.full-name")
                    }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle(String(localized: "Edit Profile", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) { Task { await save() } }
                        .disabled(saving || loading || failedToLoad || processingPhoto || name.count > 80
                                  || (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !originalName.isEmpty)
                                  || (name.trimmingCharacters(in: .whitespacesAndNewlines) == originalName && photo == nil))
                }
            }
            .interactiveDismissDisabled(saving)
            .presentationDetents([.medium, .large])
            .photosPicker(isPresented: $showingPhotoPicker, selection: $pickerItem, matching: .images)
            .task { await load() }
            .task(id: photoURL) {
                guard let url = photoURL else { return }
                let image = await LGProfileAvatarCache.image(at: url)
                if photoURL == url { originalPhoto = image }
            }
            .task(id: pickerItem) {
                guard let item = pickerItem else { return }
                processingPhoto = true
                do {
                    guard let bytes = try await item.loadTransferable(type: Data.self), let encoded = await Self.compress(bytes) else {
                        if pickerItem == item { error = String(localized: "Could not prepare the photo.", bundle: .module) }
                        if pickerItem == item { processingPhoto = false }
                        return
                    }
                    guard pickerItem == item else { return }
                    photo = encoded
                    error = nil
                } catch {
                    if pickerItem == item { self.error = String(localized: "Could not prepare the photo.", bundle: .module) }
                }
                if pickerItem == item { processingPhoto = false }
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        Group {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let originalPhoto {
                Image(uiImage: originalPhoto).resizable().scaledToFill()
            } else {
                initials
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: some View {
        Circle().fill(Color.accentColor.opacity(0.18))
            .overlay(Text(name.first.map { String($0).uppercased() } ?? "").fontWeight(.semibold))
    }

    private func load() async {
        loading = true
        failedToLoad = false
        error = nil
        defer { loading = false }
        do {
            let profile = try await readProfile()
            name = profile.fullName
            originalName = profile.fullName
            photoURL = profile.photo
        } catch {
            failedToLoad = true
            self.error = String(localized: "Could not load your profile.", bundle: .module)
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await updateProfile(name.trimmingCharacters(in: .whitespacesAndNewlines), photo)
            dismiss()
        } catch {
            self.error = String(localized: "Could not save your profile.", bundle: .module)
        }
    }

    @concurrent private static func compress(_ data: Data) async -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for size in [512, 448, 384] {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            let photo = UIImage(cgImage: image)
            for quality in [0.9, 0.82, 0.74] {
                if let bytes = photo.jpegData(compressionQuality: quality), bytes.count <= 128 * 1024 { return bytes }
            }
        }
        return nil
    }
}
