import Foundation
import LogseqModel
import Observation
import UIKit
import WidgetKit

@MainActor @Observable final class WidgetContentPublisher {
    var linkError: String?

    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private var needsBackgroundRefresh = false
    private var forceRandomReload = false

    func protectedDataDidBecomeAvailable() {
        // WidgetKit may have built a fallback timeline while the snapshot was protected.
        reloadJournalTimelines()
        resumePendingRefresh()
    }

    private func reloadJournalTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: "TodayJournalWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "CaptureWidget")
    }

    private var canRefreshInBackground: Bool {
        needsBackgroundRefresh && UIApplication.shared.applicationState == .background
    }

    private func resumePendingRefresh() {
        guard refreshTask == nil, UIApplication.shared.isProtectedDataAvailable,
              needsRefresh || canRefreshInBackground else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            while UIApplication.shared.isProtectedDataAvailable && (needsRefresh || canRefreshInBackground) {
                let explicit = needsRefresh
                let random = forceRandomReload
                let background = canRefreshInBackground
                needsRefresh = false
                forceRandomReload = false
                if background { needsBackgroundRefresh = false }
                if await publishSnapshot(forceRandomReload: random) { continue }
                needsRefresh = needsRefresh || explicit
                forceRandomReload = forceRandomReload || random
                needsBackgroundRefresh = needsBackgroundRefresh || background
                return
            }
        }
    }

    func refresh(forceRandomReload: Bool = false) async {
        needsRefresh = true
        self.forceRandomReload = self.forceRandomReload || forceRandomReload
        resumePendingRefresh()
        await refreshTask?.value
    }

    func requestBackgroundRefresh() {
        guard UIApplication.shared.applicationState == .background else { return }
        needsBackgroundRefresh = true
        resumePendingRefresh()
    }

    func refreshInBackground() async {
        guard !Task.isCancelled else { return }
        requestBackgroundRefresh()
        await refreshTask?.value
    }

    /// Returns false when data protection requires retrying the publication.
    private func publishSnapshot(forceRandomReload: Bool) async -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureStorage.appGroupIdentifier
        ) else { return true }
        let file = container.appendingPathComponent("widget-content.json")
        let response = await LogseqCore.callAsync(LogseqRPCRequest(
            method: "dispatch", params: LogseqRPCParams(
                action: "widgetSnapshot", payload: forceRandomReload ? #"{"resampleRandomBlocks":true}"# : nil
            )
        ))
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        do {
            guard let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  envelope["ok"] as? Bool == true,
                  let content = envelope["result"] as? [String: Any] else { return true }
            let data = try JSONSerialization.data(withJSONObject: content, options: .sortedKeys)
            let previousData = try? Data(contentsOf: file)
            if data != previousData {
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            }
            let previous = previousData.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            let graphChanged = previous == nil
                || previous?["graphId"] as? String != content["graphId"] as? String
                || previous?["graphLocked"] as? Bool != content["graphLocked"] as? Bool
            if previous?["journalTitlePatterns"] as? [String] != content["journalTitlePatterns"] as? [String] {
                reloadJournalTimelines()
            }
            let tasksChanged = previous?["tasks"] as? [NSDictionary] != content["tasks"] as? [NSDictionary]
            let hadRandomBlocks = (previous?["randomBlocks"] as? [NSDictionary])?.isEmpty == false
            let hasRandomBlocks = (content["randomBlocks"] as? [NSDictionary])?.isEmpty == false
            if graphChanged || tasksChanged {
                WidgetCenter.shared.reloadTimelines(ofKind: "TaskListWidget")
            }
            // The random widget picks new blocks on its own timeline once data is available.
            let randomVersionChanged = (previous?["randomBlocksVersion"] as? Int)
                != (content["randomBlocksVersion"] as? Int)
            if forceRandomReload || graphChanged || randomVersionChanged || hadRandomBlocks != hasRandomBlocks {
                WidgetCenter.shared.reloadTimelines(ofKind: "RandomBlocksWidget")
            }
        } catch let error as CocoaError
            where error.code == .fileWriteNoPermission && !UIApplication.shared.isProtectedDataAvailable {
            return false
        } catch {
            logger.error("Could not publish widget content: \(error)")
        }
        return true
    }
}
