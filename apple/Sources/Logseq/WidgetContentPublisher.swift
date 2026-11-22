import Foundation
import LogseqModel
import Observation
import WidgetKit

@MainActor @Observable final class WidgetContentPublisher {
    var linkError: String?

    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private var refreshRevision = 0
    private var publishedRevision = 0

    func scheduleRefresh() {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while needsRefresh {
                try? await Task.sleep(for: .milliseconds(750))
                needsRefresh = false
                await refresh()
            }
            refreshTask = nil
        }
    }

    func refresh() async {
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
            if data != (try? Data(contentsOf: file)) {
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                WidgetCenter.shared.reloadTimelines(ofKind: "TaskListWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "RandomBlocksWidget")
            }
            publishedRevision = revision
        } catch {
            logger.error("Could not publish widget content: \(error)")
        }
    }
}
