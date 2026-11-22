import Foundation
import LogseqModel
import Observation
import WidgetKit

@MainActor @Observable final class WidgetContentPublisher {
    var linkError: String?

    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private var forceTaskReload = false
    private var refreshRevision = 0
    private var publishedRevision = 0

    func scheduleRefresh(forceTaskReload: Bool = false) {
        needsRefresh = true
        self.forceTaskReload = self.forceTaskReload || forceTaskReload
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while needsRefresh {
                needsRefresh = false
                let forceReload = self.forceTaskReload
                self.forceTaskReload = false
                await refresh(forceTaskReload: forceReload)
            }
            refreshTask = nil
        }
    }

    func refresh(forceTaskReload: Bool = false) async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureStorage.appGroupIdentifier
        ) else { return }
        let file = container.appendingPathComponent("widget-content.json")
        refreshRevision += 1
        let revision = refreshRevision
        let response = await LogseqCore.callAsync(LogseqRPCRequest(
            method: "dispatch", params: LogseqRPCParams(action: "widgetSnapshot")
        ))
        guard revision > publishedRevision else { return }
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
            let tasksChanged = previous?["tasks"] as? [NSDictionary] != content["tasks"] as? [NSDictionary]
            let hadRandomBlocks = (previous?["randomBlocks"] as? [NSDictionary])?.isEmpty == false
            let hasRandomBlocks = (content["randomBlocks"] as? [NSDictionary])?.isEmpty == false
            if graphChanged || tasksChanged || forceTaskReload {
                WidgetCenter.shared.reloadTimelines(ofKind: "TaskListWidget")
            }
            // The random widget picks new blocks on its own timeline once data is available.
            if graphChanged || hadRandomBlocks != hasRandomBlocks {
                WidgetCenter.shared.reloadTimelines(ofKind: "RandomBlocksWidget")
            }
            publishedRevision = revision
        } catch {
            logger.error("Could not publish widget content: \(error)")
        }
    }
}
