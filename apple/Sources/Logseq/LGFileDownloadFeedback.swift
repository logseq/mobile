import SwiftUI

#if os(iOS)
/// Feedback for downloads explicitly requested by the user, shared by file and annotation links.
@MainActor @Observable
final class LGFileDownloadFeedback {
    static let shared = LGFileDownloadFeedback()

    enum Phase: String { case downloading = "Downloading file…", completed = "File downloaded", failed = "File download failed" }
    struct Notice: Equatable {
        let id: UUID
        let title: String
        var phase: Phase
    }

    private(set) var notice: Notice?
    private var active: [Notice] = []
    private var dismissal: Task<Void, Never>?

    func download(title: String, operation: () async throws -> URL) async throws -> URL {
        let item = Notice(id: UUID(), title: title, phase: .downloading)
        dismissal?.cancel()
        active.append(item)
        notice = item
        do {
            let url = try await operation()
            try Task.checkCancellation()
            finish(item, phase: .completed)
            return url
        } catch {
            finish(item, phase: Task.isCancelled || error is CancellationError ? nil : .failed)
            throw error
        }
    }

    private func finish(_ item: Notice, phase: Phase?) {
        active.removeAll { $0.id == item.id }
        if let pending = active.last { notice = pending; return }
        guard let phase else { notice = nil; return }
        notice = Notice(id: item.id, title: item.title, phase: phase)
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(phase == .failed ? 6 : 3)) }
            catch { return }
            guard self?.notice?.id == item.id else { return }
            self?.notice = nil
        }
    }
}

struct LGFileDownloadFeedbackHost: ViewModifier {
    var feedback: LGFileDownloadFeedback = .shared
    @Environment(\.locale) private var locale
    @State private var topInset: CGFloat?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = feedback.notice {
                HStack(spacing: 10) {
                    if notice.phase == .downloading { ProgressView() }
                    else { Image(systemName: notice.phase == .completed ? "checkmark.circle" : "exclamationmark.circle") }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(CaptureLocalization.text(notice.phase.rawValue, locale: locale)).font(.subheadline.weight(.medium))
                        if !notice.title.isEmpty { Text(verbatim: notice.title).font(.caption).lineLimit(2) }
                    }
                }
                .padding(12)
                .frame(maxWidth: 320, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(12)
                .padding(.top, topInset ?? 0)
                .opacity(topInset == nil ? 0 : 1)
                .background(LGNotificationSafeAreaReader { topInset = $0 })
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("asset.download-feedback")
                .allowsHitTesting(false)
            }
        }
        .onChange(of: feedback.notice) { _, notice in
            guard let notice else { return }
            UIAccessibility.post(notification: .announcement, argument:
                CaptureLocalization.text(notice.phase.rawValue, locale: locale) + " " + notice.title)
        }
    }
}
#endif
