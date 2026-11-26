import Foundation
import LogseqModel
import Observation
import UIKit
import WidgetKit

@MainActor @Observable final class WidgetContentPublisher {
    var linkError: String?

    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private var forceTaskReload = false
    private var forceRandomReload = false

    func scheduleRefresh(forceTaskReload: Bool = false, forceRandomReload: Bool = false) {
        needsRefresh = true
        self.forceTaskReload = self.forceTaskReload || forceTaskReload
        self.forceRandomReload = self.forceRandomReload || forceRandomReload
        resumePendingRefresh()
    }

    func protectedDataDidBecomeAvailable() {
        // WidgetKit may have built a fallback timeline while the snapshot was protected.
        reloadJournalTimelines()
        resumePendingRefresh()
    }

    private func reloadJournalTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: "TodayJournalWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "CaptureWidget")
    }

    private func resumePendingRefresh() {
        guard needsRefresh, refreshTask == nil, UIApplication.shared.isProtectedDataAvailable else { return }
        refreshTask = Task {
            while needsRefresh && UIApplication.shared.isProtectedDataAvailable {
                needsRefresh = false
                let forceTaskReload = self.forceTaskReload
                let forceRandomReload = self.forceRandomReload
                self.forceTaskReload = false
                self.forceRandomReload = false
                await publishSnapshot(forceTaskReload: forceTaskReload, forceRandomReload: forceRandomReload)
            }
            refreshTask = nil
        }
    }

    func refresh(forceTaskReload: Bool = false, forceRandomReload: Bool = false) async {
        scheduleRefresh(forceTaskReload: forceTaskReload, forceRandomReload: forceRandomReload)
        await refreshTask?.value
    }

    private func publishSnapshot(forceTaskReload: Bool, forceRandomReload: Bool) async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureStorage.appGroupIdentifier
        ) else { return }
        let file = container.appendingPathComponent("widget-content.json")
        let response = await LogseqCore.callAsync(LogseqRPCRequest(
            method: "dispatch", params: LogseqRPCParams(
                action: "widgetSnapshot", payload: forceRandomReload ? #"{"resampleRandomBlocks":true}"# : nil
            )
        ))
        guard UIApplication.shared.isProtectedDataAvailable else {
            scheduleRefresh(forceTaskReload: forceTaskReload, forceRandomReload: forceRandomReload)
            return
        }
        do {
            guard let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  envelope["ok"] as? Bool == true,
                  let content = envelope["result"] as? [String: Any] else { return }
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
            if graphChanged || tasksChanged || forceTaskReload {
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
            scheduleRefresh(forceTaskReload: forceTaskReload, forceRandomReload: forceRandomReload)
        } catch {
            logger.error("Could not publish widget content: \(error)")
        }
    }
}
