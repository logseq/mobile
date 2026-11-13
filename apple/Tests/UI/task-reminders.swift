import Foundation
import UserNotifications
import LogseqModel
import UIKit
@testable import Logseq

private struct TaskReminderEnvelope<Value: Decodable>: Decodable {
    let result: Value
}

private enum ReminderCenterProbeError: Error {
    case forcedAddFailure
}

private actor ReminderCenterProbe: TaskReminderCenterClient {
    private(set) var authorization: UNAuthorizationStatus
    private var requests: [TaskReminderStoredNotification]
    private var deliveredRequests: [TaskReminderStoredNotification] = []
    private var events: [String] = []
    private var triggers: [String: TaskReminderPlan.Trigger] = [:]
    private var shouldSuspendAdd = false
    private var addStarted = false
    private var addStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var addRelease: CheckedContinuation<Void, Never>?
    private var shouldFailNextAdd = false
    private var holdFailedAdd = false
    private var addFailureStarted = false
    private var addFailureWaiters: [CheckedContinuation<Void, Never>] = []
    private var addFailureRelease: CheckedContinuation<Void, Never>?
    private var shouldSuspendCleanup = false
    private var cleanupStarted = false
    private var managedCleanupStarted = false
    private var cleanupStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var managedCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupRelease: CheckedContinuation<Void, Never>?
    private var shouldSuspendAuthorization = false
    private var authorizationStarted = false
    private var authorizationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationRelease: CheckedContinuation<Void, Never>?

    init(
        authorization: UNAuthorizationStatus = .authorized,
        requests: [TaskReminderStoredNotification] = []
    ) {
        self.authorization = authorization
        self.requests = requests
    }

    func authorizationStatus() async -> UNAuthorizationStatus { authorization }
    func requestAuthorization() async throws -> Bool {
        authorizationStarted = true
        authorizationStartWaiters.forEach { $0.resume() }
        authorizationStartWaiters.removeAll()
        if shouldSuspendAuthorization {
            await withCheckedContinuation { authorizationRelease = $0 }
        }
        return authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }
    func pending() async -> [TaskReminderStoredNotification] { requests }
    func delivered() async -> [TaskReminderStoredNotification] { deliveredRequests }

    func add(_ item: TaskReminderPlan.Item) async throws {
        events.append("add")
        addStarted = true
        addStartWaiters.forEach { $0.resume() }
        addStartWaiters.removeAll()
        if shouldSuspendAdd {
            await withCheckedContinuation { addRelease = $0 }
        }
        if shouldFailNextAdd {
            shouldFailNextAdd = false
            events.append("addFailed")
            addFailureStarted = true
            addFailureWaiters.forEach { $0.resume() }
            addFailureWaiters.removeAll()
            if holdFailedAdd {
                await withCheckedContinuation { addFailureRelease = $0 }
                holdFailedAdd = false
            }
            throw ReminderCenterProbeError.forcedAddFailure
        }
        triggers[item.identifier] = item.trigger
        requests.removeAll { $0.identifier == item.identifier }
        requests.append(TaskReminderStoredNotification(
            identifier: item.identifier,
            graphId: item.graphId,
            taskUUID: item.taskUUID,
            pageId: item.pageId,
            fireDate: item.fireDate,
            trigger: item.trigger
        ))
    }

    func removePending(_ identifiers: [String]) async {
        events.append("removePending")
        if identifiers.contains(where: { $0.hasPrefix(TaskReminderPlan.managedPrefix) }) {
            managedCleanupStarted = true
            managedCleanupWaiters.forEach { $0.resume() }
            managedCleanupWaiters.removeAll()
        }
        await pauseCleanupIfRequested()
        let removed = Set(identifiers)
        requests.removeAll { removed.contains($0.identifier) }
    }

    func removeDelivered(_ identifiers: [String]) async {
        events.append("removeDelivered")
        await pauseCleanupIfRequested()
        let removed = Set(identifiers)
        deliveredRequests.removeAll { removed.contains($0.identifier) }
    }

    func suspendAdds() { shouldSuspendAdd = true }

    func failNextAdd(holdUntilReleased: Bool = false) {
        shouldFailNextAdd = true
        holdFailedAdd = holdUntilReleased
    }

    func waitForAddFailureStart() async {
        if addFailureStarted { return }
        await withCheckedContinuation { addFailureWaiters.append($0) }
    }

    func releaseHeldAddFailure() {
        addFailureRelease?.resume()
        addFailureRelease = nil
    }

    func waitForAddStart() async {
        if addStarted { return }
        await withCheckedContinuation { addStartWaiters.append($0) }
    }

    func releaseSuspendedAdd() {
        shouldSuspendAdd = false
        addRelease?.resume()
        addRelease = nil
    }

    func suspendCleanup() { shouldSuspendCleanup = true }

    func waitForCleanupStart() async {
        if cleanupStarted { return }
        await withCheckedContinuation { cleanupStartWaiters.append($0) }
    }

    func waitForManagedCleanupStart() async {
        if managedCleanupStarted { return }
        await withCheckedContinuation { managedCleanupWaiters.append($0) }
    }

    func releaseSuspendedCleanup() {
        shouldSuspendCleanup = false
        cleanupRelease?.resume()
        cleanupRelease = nil
    }

    private func pauseCleanupIfRequested() async {
        cleanupStarted = true
        cleanupStartWaiters.forEach { $0.resume() }
        cleanupStartWaiters.removeAll()
        if shouldSuspendCleanup {
            await withCheckedContinuation { cleanupRelease = $0 }
        }
    }

    func suspendAuthorization() { shouldSuspendAuthorization = true }

    func waitForAuthorizationStart() async {
        if authorizationStarted { return }
        await withCheckedContinuation { authorizationStartWaiters.append($0) }
    }

    func releaseAuthorization(as value: UNAuthorizationStatus) {
        authorization = value
        shouldSuspendAuthorization = false
        authorizationRelease?.resume()
        authorizationRelease = nil
    }

    func seed(_ request: TaskReminderStoredNotification) { requests.append(request) }
    func seedDelivered(_ request: TaskReminderStoredNotification) { deliveredRequests.append(request) }
    func setAuthorization(_ value: UNAuthorizationStatus) { authorization = value }
    func storedIDs() -> Set<String> { Set(requests.map(\.identifier)) }
    func deliveredIDs() -> Set<String> { Set(deliveredRequests.map(\.identifier)) }
    func eventLog() -> [String] { events }
    func trigger(for identifier: String) -> TaskReminderPlan.Trigger? { triggers[identifier] }
}

private actor CompletionProbe {
    private var completed = false

    func markCompleted() { completed = true }
    func hasCompleted() -> Bool { completed }
}

private final class SynchronousBackgroundCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    private var cancelCount = 0

    func record(_ value: Bool) { lock.withLock { values.append(value) } }
    func recordCancel() { lock.withLock { cancelCount += 1 } }
    func snapshot() -> (values: [Bool], cancelCount: Int) {
        lock.withLock { (values, cancelCount) }
    }
}

private actor BackgroundCompletionProbe {
    private var values: [Bool] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ value: Bool) {
        values.append(value)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func results() -> [Bool] { values }

    func waitForResult() async {
        if !values.isEmpty { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor SuspendedAsyncProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@main
struct CheckTaskReminders {
    @MainActor
    static func main() async throws {
        for (input, expected) in [("zh-Hant", "zh-Hant"), ("zh-TW", "zh-Hant"),
                                  ("zh_HK", "zh-Hant"), ("zh-CN", "zh-Hans"),
                                  ("zh-Hans-TW", "zh-Hans"), ("fr-CA", "fr")] {
            try require(taskReminderLocalization(for: input) == expected,
                        "Reminder localization did not honor language script or region: \(input)")
        }
        guard let url = Bundle.main.url(forResource: "task-reminders", withExtension: "json") else {
            throw failure("Missing generated task-reminders RPC fixture")
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let projection = try JSONDecoder().decode(
            TaskReminderEnvelope<NativeTaskReminderProjection>.self,
            from: Data(raw.utf8)
        ).result
        try require(projection.graphId == "sample", "Core RPC fixture lost its selected graph identity")
        try require(projection.ready && projection.complete, "Core RPC fixture must be a ready complete inventory")
        try require(projection.tasks.count == 48, "Expected the full synthetic graph task inventory, got \(projection.tasks.count)")
        let taskIDs = Set(projection.tasks.map(\.uuid))
        try require(taskIDs.contains("task-139"), "Core RPC omitted an offscreen task")
        try require(!taskIDs.contains("task-203") && !taskIDs.contains("task-204") && !taskIDs.contains("task-206"),
                    "Deleted, completed, and recurring tasks must be excluded by the core engine")
        try require(taskIDs.contains("task-205"),
                    "A nonrecurring task with a false recurrence marker was incorrectly omitted")
        try require(taskIDs.contains("task-207") && taskIDs.contains("task-208"),
                    "Core RPC omitted UTC-midnight or Scheduled-placeholder/Deadline-fallback cases")
        try require(taskIDs.contains("task-209") && taskIDs.contains("task-210"),
                    "Core RPC omitted wrapped datetime value and block/title date reference cases")
        try require(!["task-211", "task-212", "task-213", "task-214"].contains(where: { taskIDs.contains($0) }),
                    "Malformed date, placeholder-with-fallback, or recurrence alias conflicts were not excluded")
        let deadlineFallback = try require(projection.tasks.first(where: { $0.uuid == "task-208" }),
                                           "Missing empty-Scheduled/Deadline-fallback task")
        guard case .datetime(let fallbackTimestamp) = deadlineFallback.temporal,
              fallbackTimestamp == 10 else {
            throw failure("Empty Scheduled placeholder did not fall back to the Deadline timestamp")
        }
        print("PASS: decoded genuine taskReminders RPC JSON for the complete synthetic graph")

        let now = date("2026-11-11T00:00:00Z")
        let utc = TimeZone(secondsFromGMT: 0)!
        let plan = TaskReminderPlan.make(from: projection, now: now, timeZone: utc)
        let future = try require(plan.items.first(where: { $0.taskUUID == "task-202" }),
                                 "Expected the future exact-datetime core task in the plan")
        try require(future.fireDate == date("2026-11-12T12:00:00Z"),
                    "Datetime trigger shifted from its exact core timestamp: \(future.fireDate)")
        let exactComponents = future.triggerDateComponents
        try require(future.trigger == .instant
                    && exactComponents.calendar?.identifier == .gregorian
                    && exactComponents.timeZone == .gmt
                    && exactComponents.year == 2026 && exactComponents.month == 11
                    && exactComponents.day == 12 && exactComponents.hour == 12,
                    "Exact datetime reminders must use the original GMT instant components")
        try require(TaskReminderPlan.Trigger.from(exactComponents) == .instant,
                    "GMT trigger components did not decode as an exact datetime")
        try require(plan.items.contains(where: { $0.taskUUID == "task-209" && $0.fireDate == future.fireDate })
                    && plan.items.contains(where: { $0.taskUUID == "task-210" && $0.fireDate == future.fireDate }),
                    "Wrapped datetime and block/title date-reference tasks lost their exact instant")
        try require(future.graphId == "sample" && future.pageId == "page",
                    "Planned reminder lost graph or original page context")
        try require(!plan.items.contains(where: { $0.taskUUID == "task-200" || $0.taskUUID == "task-201" }),
                    "Past datetime reminders must not be scheduled")
        try require(!plan.items.contains(where: { $0.taskUUID == "task-208" }),
                    "Past deadline fallback must not create an immediate notification")
        let midnightItem = try require(plan.items.first(where: { $0.taskUUID == "task-207" }),
                                       "Expected the UTC-midnight datetime core task in the plan")
        try require(midnightItem.fireDate == date("2026-12-01T00:00:00Z"),
                    "UTC-midnight datetime was changed by timezone conversion: \(midnightItem.fireDate)")
        print("PASS: production planner preserves future UTC datetime, graph/page context, and skips past alerts")

        guard let dateURL = Bundle.main.url(forResource: "task-reminders-date", withExtension: "json") else {
            throw failure("Missing generated date-typed taskReminders RPC fixture")
        }
        let dateRaw = try String(contentsOf: dateURL, encoding: .utf8)
        let dateProjection = try JSONDecoder().decode(
            TaskReminderEnvelope<NativeTaskReminderProjection>.self,
            from: Data(dateRaw.utf8)
        ).result
        try require(dateProjection.tasks.contains(where: { $0.uuid == "task-date" }),
                    "Expected the date-typed core projection from its separate synthetic schema")
        let movedDateProjection = NativeTaskReminderProjection(
            graphId: dateProjection.graphId,
            ready: dateProjection.ready,
            complete: dateProjection.complete,
            tasks: dateProjection.tasks.map {
                NativeTaskReminderProjection.Task(
                    uuid: $0.uuid, pageId: "page-B", temporal: $0.temporal
                )
            }
        )
        let currentTaskContext = try require(TaskReminderRouteResolver.resolve(
            graphId: "sample", taskUUID: "task-date", in: movedDateProjection
        ), "A task moved within its graph should still resolve from its current projection")
        try require(currentTaskContext.pageId == "page-B",
                    "A reminder tap kept its stale notification page instead of the task's current page")
        try require(TaskReminderRouteResolver.resolve(
            graphId: "other-graph", taskUUID: "task-date", in: movedDateProjection
        ) == nil, "A task route must not cross into another graph")
        print("PASS: reminder route lookup resolves a moved task's current page and rejects other graphs")
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let datePlan = TaskReminderPlan.make(
            from: dateProjection,
            now: now,
            timeZone: losAngeles
        )
        let dateItem = try require(datePlan.items.first, "Typed date task was not planned")
        try require(dateItem.fireDate == date("2026-11-12T17:00:00Z"),
                    "Typed date must fire at 9 AM local time in Los Angeles: \(dateItem.fireDate)")
        let floatingComponents = dateItem.triggerDateComponents
        try require(dateItem.trigger == .localDate(20261112)
                    && floatingComponents.calendar?.identifier == .gregorian
                    && floatingComponents.year == 2026 && floatingComponents.month == 11
                    && floatingComponents.day == 12 && floatingComponents.hour == 9
                    && floatingComponents.minute == 0 && floatingComponents.second == 0
                    && floatingComponents.timeZone == nil,
                    "Date-only notifications must float at 9 AM on the Gregorian journal day")
        try require(TaskReminderPlan.Trigger.from(floatingComponents) == .localDate(20261112),
                    "Floating local date components did not round-trip")
        let leapProjection = try JSONDecoder().decode(
            TaskReminderEnvelope<NativeTaskReminderProjection>.self,
            from: Data(#"{"result":{"graphId":"date-sample","ready":true,"complete":true,"tasks":[{"uuid":"leap","pageId":"source-page","temporal":{"kind":"date","day":20240229}},{"uuid":"invalid-leap","pageId":"source-page","temporal":{"kind":"date","day":20260229}}]}}"#.utf8)
        ).result
        let leapPlan = TaskReminderPlan.make(
            from: leapProjection,
            now: date("2024-02-28T00:00:00Z"),
            timeZone: utc
        )
        try require(leapPlan.items.count == 1 && leapPlan.items[0].taskUUID == "leap",
                    "Date planner must accept Gregorian leap days and reject invalid calendar dates")
        let dstProjection = try JSONDecoder().decode(
            TaskReminderEnvelope<NativeTaskReminderProjection>.self,
            from: Data(#"{"result":{"graphId":"date-sample","ready":true,"complete":true,"tasks":[{"uuid":"dst-start","pageId":"source-page","temporal":{"kind":"date","day":20260308}}]}}"#.utf8)
        ).result
        let dstPlan = TaskReminderPlan.make(
            from: dstProjection,
            now: date("2026-03-07T00:00:00Z"),
            timeZone: losAngeles
        )
        try require(dstPlan.items.first?.fireDate == date("2026-03-08T16:00:00Z"),
                    "9 AM date-only reminder did not follow daylight saving time")
        try require(dstPlan.items.first?.trigger == .localDate(20260308),
                    "DST date-only reminder lost its floating local calendar day")
        print("PASS: typed dates use Gregorian journal days at 9 AM local across leap day and DST; core UTC-midnight datetime keeps its exact instant")

        let unrelatedID = "another.app.notification"
        let center = ReminderCenterProbe(requests: [TaskReminderStoredNotification(
            identifier: unrelatedID, graphId: nil, taskUUID: nil, pageId: nil, fireDate: nil, trigger: nil
        )])
        let adapter = TaskReminderNotificationAdapter(center: center)
        let defaultsSuite = "TaskReminderRuntimeCheck-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let coordinator = TaskReminderCoordinator(adapter: adapter, defaults: defaults, now: { now })
        try require(!coordinator.isEnabled, "App-level task reminder opt-in must default off")
        await coordinator.setEnabled(true)
        try require(coordinator.isEnabled, "Authorized opt-in did not enable task reminders")
        let scopeBeforeRefresh = coordinator.currentScopeEpoch
        let refreshToken = coordinator.beginRefresh()
        try require(await coordinator.reconcile(
            raw, expectedGraphID: "sample", refreshToken: refreshToken
        ), "Fresh same-graph core response did not reconcile")
        try require(coordinator.currentScopeEpoch == scopeBeforeRefresh,
                    "A same-graph task refresh must not invalidate tap navigation scope")
        for _ in 0..<100 {
            if await center.storedIDs().contains(future.identifier) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let afterPlan = await center.storedIDs()
        try require(afterPlan.contains(unrelatedID), "Reconciliation removed an unrelated notification")
        try require(afterPlan.contains(future.identifier), "Reconciliation did not add the core-projected task reminder")
        for (ready, complete) in [(false, true), (true, false)] {
            let incompleteCenter = ReminderCenterProbe(requests: [
                TaskReminderStoredNotification(identifier: future.identifier, graphId: future.graphId,
                    taskUUID: future.taskUUID, pageId: future.pageId, fireDate: future.fireDate, trigger: future.trigger),
                TaskReminderStoredNotification(identifier: unrelatedID, graphId: nil,
                    taskUUID: nil, pageId: nil, fireDate: nil, trigger: nil)
            ])
            let suite = "TaskReminderIncomplete-\(UUID().uuidString)"
            let incompleteDefaults = UserDefaults(suiteName: suite)!
            defer { incompleteDefaults.removePersistentDomain(forName: suite) }
            let incompleteCoordinator = TaskReminderCoordinator(
                adapter: TaskReminderNotificationAdapter(center: incompleteCenter),
                defaults: incompleteDefaults, now: { now }
            )
            await incompleteCoordinator.setEnabled(true)
            await incompleteCenter.suspendCleanup()
            let token = incompleteCoordinator.beginRefresh()
            let completion = CompletionProbe()
            let response = #"{"result":{"graphId":"sample","ready":\#(ready),"complete":\#(complete),"tasks":[]}}"#
            let task = Task {
                let result = await incompleteCoordinator.reconcile(response, expectedGraphID: "sample", refreshToken: token)
                await completion.markCompleted()
                return result
            }
            await incompleteCenter.waitForManagedCleanupStart()
            try require(!(await completion.hasCompleted()), "Incomplete projection returned before cleanup")
            await incompleteCenter.releaseSuspendedCleanup()
            try require(!(await task.value), "Incomplete projection reported success")
            try require(await incompleteCenter.storedIDs() == [unrelatedID], "Incomplete projection failed selective cleanup")
        }
        print("PASS: genuine core RPC JSON flows through the production coordinator and adapter while unrelated requests remain")
        await coordinator.invalidateForGraphMutation()
        try require(coordinator.currentScopeEpoch > scopeBeforeRefresh,
                    "A graph-scope change did not invalidate previously captured task taps")
        try require(await center.storedIDs() == [unrelatedID],
                    "Graph-scope invalidation did not clear managed requests selectively")
        print("PASS: same-graph refresh retains tap scope; graph mutation advances scope and clears managed reminders")

        let mismatchResponse = raw.replacingOccurrences(
            of: #""graphId":"sample""#,
            with: #""graphId":"graph-B""#,
            range: raw.range(of: #""graphId":"sample""#)
        )
        let mismatchCenter = ReminderCenterProbe(requests: [
            TaskReminderStoredNotification(
                identifier: future.identifier, graphId: future.graphId,
                taskUUID: future.taskUUID, pageId: future.pageId, fireDate: future.fireDate,
                trigger: future.trigger
            ),
            TaskReminderStoredNotification(
                identifier: unrelatedID, graphId: nil, taskUUID: nil, pageId: nil, fireDate: nil, trigger: nil
            )
        ])
        let mismatchSuite = "TaskReminderGraphMismatch-\(UUID().uuidString)"
        let mismatchDefaults = UserDefaults(suiteName: mismatchSuite)!
        defer { mismatchDefaults.removePersistentDomain(forName: mismatchSuite) }
        let mismatchCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: mismatchCenter),
            defaults: mismatchDefaults,
            now: { now }
        )
        await mismatchCoordinator.setEnabled(true)
        let mismatchToken = mismatchCoordinator.beginRefresh()
        try require(!(await mismatchCoordinator.reconcile(
            mismatchResponse, expectedGraphID: "sample", refreshToken: mismatchToken
        )), "A mismatched graph response unexpectedly reconciled")
        try require(await mismatchCenter.storedIDs() == [unrelatedID],
                    "A graph-B response added reminders or retained stale graph-A managed requests")
        print("PASS: graph mismatch clears managed reminders and creates no cross-graph requests")
        await center.setAuthorization(.denied)
        await coordinator.refreshPermissionStatus()
        for _ in 0..<100 {
            let requests = await center.storedIDs()
            if !coordinator.isEnabled && requests == [unrelatedID] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(!coordinator.isEnabled,
                    "Coordinator kept notifications enabled after authorization was revoked")
        try require(coordinator.currentScopeEpoch > scopeBeforeRefresh,
                    "Permission revocation did not invalidate task navigation scope")
        try require(await center.storedIDs() == [unrelatedID],
                    "Authorization revocation did not clear managed reminders selectively")
        print("PASS: authorization revocation disables the opt-in and removes only managed reminders")

        let rescheduleCenter = ReminderCenterProbe(requests: [
            TaskReminderStoredNotification(
                identifier: future.identifier, graphId: future.graphId, taskUUID: future.taskUUID,
                pageId: future.pageId, fireDate: future.fireDate.addingTimeInterval(60),
                trigger: future.trigger
            ),
            TaskReminderStoredNotification(identifier: unrelatedID, graphId: nil, taskUUID: nil, pageId: nil, fireDate: nil, trigger: nil)
        ])
        await rescheduleCenter.seedDelivered(TaskReminderStoredNotification(
            identifier: future.identifier, graphId: future.graphId, taskUUID: future.taskUUID,
            pageId: future.pageId, fireDate: future.fireDate, trigger: future.trigger
        ))
        let pastOpenProjection = NativeTaskReminderProjection(
            graphId: "sample", ready: true, complete: true,
            tasks: [NativeTaskReminderProjection.Task(
                uuid: "past-open", pageId: "page", temporal: .datetime(1_577_836_800_000)
            )]
        )
        let pastOpenPlan = TaskReminderPlan.make(from: pastOpenProjection, now: now, timeZone: utc)
        let pastOpenID = try require(pastOpenPlan.openTaskIdentifiers.first,
                                    "Expected an identifier for an eligible overdue open task")
        await rescheduleCenter.seedDelivered(TaskReminderStoredNotification(
            identifier: pastOpenID, graphId: "sample", taskUUID: "past-open",
            pageId: "page", fireDate: date("2020-01-01T00:00:00Z"), trigger: .instant
        ))
        await rescheduleCenter.seedDelivered(TaskReminderStoredNotification(
            identifier: "another.app.delivered", graphId: nil, taskUUID: nil, pageId: nil, fireDate: nil, trigger: nil
        ))
        let rescheduler = TaskReminderNotificationAdapter(center: rescheduleCenter)
        await rescheduler.reconcile(
            TaskReminderPlan(
                items: plan.items,
                openTaskIdentifiers: plan.openTaskIdentifiers.union(pastOpenPlan.openTaskIdentifiers)
            ),
            epoch: 1
        )
        let repairedRequest = await rescheduleCenter.pending().first { $0.identifier == future.identifier }
        try require(repairedRequest?.fireDate == future.fireDate,
                    "Changed task deadline was not rescheduled to the updated instant")
        let deliveredAfterReschedule = await rescheduleCenter.deliveredIDs()
        try require(!deliveredAfterReschedule.contains(future.identifier),
                    "A future task's delivered alert must be cleared when it is rescheduled")
        try require(deliveredAfterReschedule.contains(pastOpenID),
                    "An eligible overdue open task's delivered alert should remain until the task is resolved")
        let emptyPlan = TaskReminderPlan(items: [], openTaskIdentifiers: [])
        await rescheduler.reconcile(emptyPlan, epoch: 2)
        let afterRemoval = await rescheduleCenter.storedIDs()
        let deliveredAfterRemoval = await rescheduleCenter.deliveredIDs()
        try require(!afterRemoval.contains(future.identifier) && afterRemoval.contains(unrelatedID),
                    "Task removal must cancel only managed pending requests")
        try require(!deliveredAfterRemoval.contains(future.identifier)
                    && !deliveredAfterRemoval.contains(pastOpenID)
                    && deliveredAfterRemoval.contains("another.app.delivered"),
                    "Task completion must clear managed delivered alerts and preserve unrelated alerts")
        let rescheduleEvents = await rescheduleCenter.eventLog()
        try require(rescheduleEvents.firstIndex(of: "removePending")! < rescheduleEvents.firstIndex(of: "add")!,
                    "Rescheduling must remove the stale trigger before adding its replacement")
        let movedDatePlan = TaskReminderPlan.make(
            from: movedDateProjection, now: now, timeZone: losAngeles
        )
        let movedCenter = ReminderCenterProbe(requests: [TaskReminderStoredNotification(
            identifier: dateItem.identifier, graphId: dateItem.graphId, taskUUID: dateItem.taskUUID,
            pageId: dateItem.pageId, fireDate: dateItem.fireDate, trigger: dateItem.trigger
        )])
        await TaskReminderNotificationAdapter(center: movedCenter).reconcile(movedDatePlan, epoch: 1)
        let movedRequest = await movedCenter.pending().first { $0.identifier == dateItem.identifier }
        try require(movedRequest?.pageId == "page-B" && movedRequest?.fireDate == dateItem.fireDate,
                    "A same-graph page move must update reminder context without changing its trigger")
        let sameInstantProjection = NativeTaskReminderProjection(
            graphId: "sample", ready: true, complete: true,
            tasks: [NativeTaskReminderProjection.Task(
                uuid: "task-date", pageId: "source-page", temporal: .datetime(1_794_502_800_000)
            )]
        )
        let sameInstantPlan = TaskReminderPlan.make(
            from: sameInstantProjection, now: now, timeZone: losAngeles
        )
        let instantItem = try require(sameInstantPlan.items.first,
                                      "Expected the same-instant datetime schema change")
        try require(instantItem.fireDate == dateItem.fireDate && instantItem.trigger == .instant,
                    "Schema-change fixture must retain its instant while changing trigger semantics")
        let schemaChangeCenter = ReminderCenterProbe(requests: [TaskReminderStoredNotification(
            identifier: dateItem.identifier, graphId: dateItem.graphId, taskUUID: dateItem.taskUUID,
            pageId: dateItem.pageId, fireDate: dateItem.fireDate, trigger: dateItem.trigger
        )])
        await TaskReminderNotificationAdapter(center: schemaChangeCenter).reconcile(sameInstantPlan, epoch: 1)
        let schemaChangeRequest = await schemaChangeCenter.pending().first {
            $0.identifier == instantItem.identifier
        }
        try require(schemaChangeRequest?.fireDate == dateItem.fireDate
                    && schemaChangeRequest?.trigger == .instant,
                    "Same-instant date→datetime edit did not replace the floating trigger with a GMT instant")
        print("PASS: changed times reschedule; removed/completed tasks cancel pending and delivered alerts selectively")

        let raceCenter = ReminderCenterProbe()
        await raceCenter.suspendAdds()
        let raceAdapter = TaskReminderNotificationAdapter(center: raceCenter)
        let reconcile = Task { await raceAdapter.reconcile(plan, epoch: 1) }
        await raceCenter.waitForAddStart()
        let invalidate = Task { await raceAdapter.invalidate(to: 2) }
        await raceCenter.releaseSuspendedAdd()
        try require(!(await reconcile.value),
                    "A superseded notification reconciliation unexpectedly reported success")
        await invalidate.value
        try require(await raceCenter.storedIDs().isEmpty,
                    "An add completing after graph invalidation left a stale reminder")
        print("PASS: invalidation removes an add that completes after a graph-scope change")

        let drainCenter = ReminderCenterProbe()
        await drainCenter.suspendAdds()
        let drainSuite = "TaskReminderRefreshDrain-\(UUID().uuidString)"
        let drainDefaults = UserDefaults(suiteName: drainSuite)!
        defer { drainDefaults.removePersistentDomain(forName: drainSuite) }
        let drainCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: drainCenter),
            defaults: drainDefaults,
            now: { now }
        )
        await drainCoordinator.setEnabled(true)
        let drainCompletion = CompletionProbe()
        let drainTask = Task {
            let result = await drainCoordinator.refreshAndDrain(
                expectedGraphID: "sample",
                fetchProjection: { raw }
            )
            await drainCompletion.markCompleted()
            return result
        }
        await drainCenter.waitForAddStart()
        try require(!(await drainCompletion.hasCompleted()),
                    "Background refresh returned before its notification add drained")
        await drainCenter.releaseSuspendedAdd()
        try require(await drainTask.value,
                    "A current ready-graph refresh did not complete successfully")
        let drainDidComplete = await drainCompletion.hasCompleted()
        let drainedIDs = await drainCenter.storedIDs()
        try require(drainDidComplete && drainedIDs.contains(future.identifier),
                    "Refresh completion was reported before the managed notification write finished")

        let supersededCenter = ReminderCenterProbe()
        await supersededCenter.suspendAdds()
        let supersededSuite = "TaskReminderRefreshSuperseded-\(UUID().uuidString)"
        let supersededDefaults = UserDefaults(suiteName: supersededSuite)!
        defer { supersededDefaults.removePersistentDomain(forName: supersededSuite) }
        let supersededCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: supersededCenter),
            defaults: supersededDefaults,
            now: { now }
        )
        await supersededCoordinator.setEnabled(true)
        let navigationScopeBeforeRefresh = supersededCoordinator.currentScopeEpoch
        let staleRefresh = Task {
            await supersededCoordinator.refreshAndDrain(
                expectedGraphID: "sample",
                fetchProjection: { raw }
            )
        }
        await supersededCenter.waitForAddStart()
        let writerEpochBeforeRefresh = supersededCoordinator.currentEpoch
        _ = supersededCoordinator.beginRefresh()
        try require(supersededCoordinator.currentEpoch > writerEpochBeforeRefresh
                    && supersededCoordinator.currentScopeEpoch == navigationScopeBeforeRefresh
                    && supersededCoordinator.isEnabled,
                    "A task refresh did not fence writes immediately without changing graph scope or consent")
        await supersededCenter.releaseSuspendedAdd()
        try require(!(await staleRefresh.value),
                    "A superseded refresh reported success")
        try require(await supersededCenter.storedIDs().isEmpty,
                    "A superseded refresh returned before stale managed cleanup completed")
        try require(supersededCoordinator.currentScopeEpoch == navigationScopeBeforeRefresh
                    && supersededCoordinator.isEnabled,
                    "Refresh supersession changed navigation scope or app-level consent")

        // A newer no-op refresh must not cancel mandatory disable cleanup that
        // is waiting behind a notification write.
        let mandatoryRaw = #"{"result":{"graphId":"sample","ready":true,"complete":true,"tasks":[{"uuid":"a","pageId":"p","temporal":{"kind":"datetime","timestampMs":4070908800000}},{"uuid":"b","pageId":"p","temporal":{"kind":"datetime","timestampMs":4070908800000}}]}}"#
        let mandatoryProjection = try JSONDecoder().decode(
            TaskReminderRPCEnvelope<NativeTaskReminderProjection>.self, from: Data(mandatoryRaw.utf8)
        ).result
        let existing = TaskReminderPlan.make(from: mandatoryProjection, now: now).items[0]
        let mandatoryCenter = ReminderCenterProbe(requests: [TaskReminderStoredNotification(
            identifier: existing.identifier, graphId: existing.graphId, taskUUID: existing.taskUUID,
            pageId: existing.pageId, fireDate: existing.fireDate, trigger: existing.trigger
        )])
        await mandatoryCenter.suspendAdds()
        let mandatorySuite = "TaskReminderMandatoryCleanup-\(UUID().uuidString)"
        let mandatoryDefaults = UserDefaults(suiteName: mandatorySuite)!
        defer { mandatoryDefaults.removePersistentDomain(forName: mandatorySuite) }
        let mandatoryCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: mandatoryCenter), defaults: mandatoryDefaults, now: { now }
        )
        await mandatoryCoordinator.setEnabled(true)
        let mandatoryToken = mandatoryCoordinator.beginRefresh()
        let heldWrite = Task {
            await mandatoryCoordinator.reconcile(mandatoryRaw, expectedGraphID: "sample", refreshToken: mandatoryToken)
        }
        await mandatoryCenter.waitForAddStart()
        let disable = Task { await mandatoryCoordinator.setEnabled(false) }
        while mandatoryCoordinator.isEnabled { await Task.yield() }
        _ = mandatoryCoordinator.beginRefresh()
        await mandatoryCenter.releaseSuspendedAdd()
        _ = await heldWrite.value
        await disable.value
        try require(await mandatoryCenter.storedIDs().isEmpty,
                    "A newer no-op epoch skipped mandatory disable cleanup")

        // An old background read can finish after a newer foreground write, or
        // while that write is suspended. Neither ordering may cancel the newer work.
        for newerInFlight in [false, true] {
            let raceCenter = ReminderCenterProbe()
            if newerInFlight { await raceCenter.suspendAdds() }
            let suite = "TaskReminderNewerRefresh-\(UUID().uuidString)"
            let raceDefaults = UserDefaults(suiteName: suite)!
            defer { raceDefaults.removePersistentDomain(forName: suite) }
            let raceCoordinator = TaskReminderCoordinator(
                adapter: TaskReminderNotificationAdapter(center: raceCenter),
                defaults: raceDefaults, now: { now }
            )
            await raceCoordinator.setEnabled(true)
            let oldFetch = SuspendedAsyncProbe()
            let oldTask = Task {
                await raceCoordinator.refreshAndDrain(expectedGraphID: "sample") {
                    await oldFetch.run()
                    return nil
                }
            }
            await oldFetch.waitForStart()
            let newerToken = raceCoordinator.beginRefresh()
            let newerTask = Task {
                await raceCoordinator.reconcile(raw, expectedGraphID: "sample", refreshToken: newerToken)
            }
            if newerInFlight {
                await raceCenter.waitForAddStart()
            } else {
                try require(await newerTask.value, "Newer refresh did not finish")
            }
            await oldFetch.release()
            try require(!(await oldTask.value), "Superseded background read reported success")
            if newerInFlight { await raceCenter.releaseSuspendedAdd() }
            try require(await newerTask.value, "Old background read invalidated a newer refresh")
            try require(await raceCenter.storedIDs().contains(future.identifier),
                        "Old background read removed the newer reminder")
        }
        let disabledDrainCenter = ReminderCenterProbe()
        await disabledDrainCenter.suspendAdds()
        let disabledDrainSuite = "TaskReminderDisabledDrain-\(UUID().uuidString)"
        let disabledDrainDefaults = UserDefaults(suiteName: disabledDrainSuite)!
        defer { disabledDrainDefaults.removePersistentDomain(forName: disabledDrainSuite) }
        let disabledDrainCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: disabledDrainCenter),
            defaults: disabledDrainDefaults,
            now: { now }
        )
        await disabledDrainCoordinator.setEnabled(true)
        let preDisableRefresh = Task {
            await disabledDrainCoordinator.refreshAndDrain(
                expectedGraphID: "sample",
                fetchProjection: { raw }
            )
        }
        await disabledDrainCenter.waitForAddStart()
        let disableDuringAdd = Task { await disabledDrainCoordinator.setEnabled(false) }
        for _ in 0..<100 where disabledDrainCoordinator.isEnabled {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!disabledDrainCoordinator.isEnabled,
                    "The explicit disable did not take effect before the suspended add resumed")
        let navigationScopeAfterDisable = disabledDrainCoordinator.currentScopeEpoch
        await disabledDrainCenter.suspendCleanup()
        await disabledDrainCenter.releaseSuspendedAdd()
        await disabledDrainCenter.waitForCleanupStart()
        let disabledDrainCompletion = CompletionProbe()
        let disabledDrainTask = Task {
            let result = await disabledDrainCoordinator.refreshAndDrain(
                expectedGraphID: "sample",
                fetchProjection: { raw }
            )
            await disabledDrainCompletion.markCompleted()
            return result
        }
        await disabledDrainCenter.waitForCleanupStart()
        try require(!(await disabledDrainCompletion.hasCompleted()),
                    "A disabled refresh completed before stale reminder cleanup drained")
        await disabledDrainCenter.releaseSuspendedCleanup()
        await disableDuringAdd.value
        try require(!(await preDisableRefresh.value),
                    "The pre-disable suspended refresh unexpectedly reported success")
        try require(await disabledDrainTask.value,
                    "A disabled refresh cleanup did not finish normally")
        let disabledDrainIDs = await disabledDrainCenter.storedIDs()
        try require(disabledDrainIDs.isEmpty
                    && disabledDrainCoordinator.currentScopeEpoch == navigationScopeAfterDisable
                    && !disabledDrainCoordinator.isEnabled,
                    "Disabled refresh cleanup did not remove only stale managed requests")

        let failedDrainCenter = ReminderCenterProbe(requests: [
            TaskReminderStoredNotification(
                identifier: future.identifier, graphId: future.graphId,
                taskUUID: future.taskUUID, pageId: future.pageId,
                fireDate: future.fireDate, trigger: future.trigger
            ),
            TaskReminderStoredNotification(
                identifier: unrelatedID, graphId: nil, taskUUID: nil,
                pageId: nil, fireDate: nil, trigger: nil
            )
        ])
        await failedDrainCenter.suspendCleanup()
        let failedDrainSuite = "TaskReminderFailedDrain-\(UUID().uuidString)"
        let failedDrainDefaults = UserDefaults(suiteName: failedDrainSuite)!
        defer { failedDrainDefaults.removePersistentDomain(forName: failedDrainSuite) }
        let failedDrainCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: failedDrainCenter),
            defaults: failedDrainDefaults,
            now: { now }
        )
        await failedDrainCoordinator.setEnabled(true)
        let failedDrainCompletion = CompletionProbe()
        let failedDrainTask = Task {
            let result = await failedDrainCoordinator.refreshAndDrain(
                expectedGraphID: "sample",
                fetchProjection: { nil }
            )
            await failedDrainCompletion.markCompleted()
            return result
        }
        await failedDrainCenter.waitForCleanupStart()
        try require(!(await failedDrainCompletion.hasCompleted()),
                    "A failed background refresh returned before managed cleanup drained")
        await failedDrainCenter.releaseSuspendedCleanup()
        try require(!(await failedDrainTask.value),
                    "A refresh with a failed core read unexpectedly reported success")
        let failedDrainIDs = await failedDrainCenter.storedIDs()
        try require(failedDrainIDs == [unrelatedID],
                    "Failed refresh did not await selective cleanup of stale managed requests")
        print("PASS: background refresh awaits writes; disable, failure, and supersession drain managed cleanup")

        let adapterFailureCenter = ReminderCenterProbe()
        await adapterFailureCenter.failNextAdd()
        let adapterFailureResult = await TaskReminderNotificationAdapter(center: adapterFailureCenter)
            .reconcile(plan, epoch: 1)
        try require(!adapterFailureResult,
                    "The notification adapter reported success after the center rejected an add")
        let adapterFailureEvents = await adapterFailureCenter.eventLog()
        let adapterFailureIDs = await adapterFailureCenter.storedIDs()
        try require(adapterFailureEvents.contains("addFailed"),
                    "The adapter failure probe did not reach the injected add rejection")
        try require(adapterFailureIDs.isEmpty,
                    "The adapter failure probe retained a request after the injected rejection")

        let coordinatorFailureCenter = ReminderCenterProbe()
        await coordinatorFailureCenter.failNextAdd()
        let coordinatorFailureSuite = "TaskReminderAddFailure-\(UUID().uuidString)"
        let coordinatorFailureDefaults = UserDefaults(suiteName: coordinatorFailureSuite)!
        defer { coordinatorFailureDefaults.removePersistentDomain(forName: coordinatorFailureSuite) }
        let coordinatorFailure = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: coordinatorFailureCenter),
            defaults: coordinatorFailureDefaults,
            now: { now }
        )
        await coordinatorFailure.setEnabled(true)
        let coordinatorFailureToken = coordinatorFailure.beginRefresh()
        let coordinatorFailureResult = await coordinatorFailure.reconcile(
            raw, expectedGraphID: "sample", refreshToken: coordinatorFailureToken
        )
        try require(!coordinatorFailureResult,
                    "The coordinator reported success after the notification center rejected an add")
        try require(await coordinatorFailureCenter.eventLog().contains("addFailed"),
                    "Coordinator failure result was not caused by the injected center add rejection")
        try require(coordinatorFailure.statusForSettings == "Could not schedule task reminders.",
                    "Settings did not report the scheduling failure")
        await coordinatorFailure.refreshPermissionStatus()
        try require(coordinatorFailure.statusForSettings == "Could not schedule task reminders.",
                    "Permission refresh erased the scheduling failure")
        let retryToken = coordinatorFailure.beginRefresh()
        try require(await coordinatorFailure.reconcile(raw, expectedGraphID: "sample", refreshToken: retryToken),
                    "Scheduling retry did not succeed")
        try require(coordinatorFailure.statusForSettings == "Local alerts for scheduled tasks and deadlines.",
                    "Successful scheduling did not clear the failure status")

        let staleFailureCenter = ReminderCenterProbe()
        await staleFailureCenter.failNextAdd(holdUntilReleased: true)
        let staleFailureSuite = "TaskReminderStaleFailure-\(UUID().uuidString)"
        let staleFailureDefaults = UserDefaults(suiteName: staleFailureSuite)!
        defer { staleFailureDefaults.removePersistentDomain(forName: staleFailureSuite) }
        let staleFailureCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: staleFailureCenter),
            defaults: staleFailureDefaults, now: { now }
        )
        await staleFailureCoordinator.setEnabled(true)
        let staleToken = staleFailureCoordinator.beginRefresh()
        let staleFailure = Task {
            await staleFailureCoordinator.reconcile(raw, expectedGraphID: "sample", refreshToken: staleToken)
        }
        await staleFailureCenter.waitForAddFailureStart()
        let latestToken = staleFailureCoordinator.beginRefresh()
        await staleFailureCenter.releaseHeldAddFailure()
        try require(!(await staleFailure.value), "Superseded failed add reported success")
        try require(staleFailureCoordinator.statusForSettings == "Local alerts for scheduled tasks and deadlines.",
                    "Superseded failure replaced the current settings status")
        try require(await staleFailureCoordinator.reconcile(raw, expectedGraphID: "sample", refreshToken: latestToken),
                    "New refresh failed after a superseded add failure")

        let staleFetch = SuspendedAsyncProbe()
        let staleBackground = Task {
            await staleFailureCoordinator.refreshAndDrain(expectedGraphID: "sample") {
                await staleFetch.run()
                return nil
            }
        }
        await staleFetch.waitForStart()
        // Change the plan so the injected rejection cannot reuse an existing request.
        let changedResponse = raw.replacingOccurrences(of: "task-202", with: "task-new-status")
        await staleFailureCenter.failNextAdd()
        let failedLatestToken = staleFailureCoordinator.beginRefresh()
        try require(!(await staleFailureCoordinator.reconcile(
            changedResponse, expectedGraphID: "sample", refreshToken: failedLatestToken
        )), "Latest injected add failure reported success")
        await staleFetch.release()
        try require(!(await staleBackground.value), "Old background read reported success")
        try require(staleFailureCoordinator.statusForSettings == "Could not schedule task reminders.",
                    "Old background read erased the latest failure status")

        let backgroundAddFailureCenter = ReminderCenterProbe(requests: [
            TaskReminderStoredNotification(
                identifier: future.identifier, graphId: future.graphId,
                taskUUID: future.taskUUID, pageId: future.pageId,
                fireDate: future.fireDate, trigger: future.trigger
            ),
            TaskReminderStoredNotification(
                identifier: unrelatedID, graphId: nil, taskUUID: nil,
                pageId: nil, fireDate: nil, trigger: nil
            )
        ])
        await backgroundAddFailureCenter.failNextAdd(holdUntilReleased: true)
        let backgroundAddFailureSuite = "TaskReminderBackgroundAddFailure-\(UUID().uuidString)"
        let backgroundAddFailureDefaults = UserDefaults(suiteName: backgroundAddFailureSuite)!
        defer { backgroundAddFailureDefaults.removePersistentDomain(forName: backgroundAddFailureSuite) }
        let backgroundAddFailureCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: backgroundAddFailureCenter),
            defaults: backgroundAddFailureDefaults,
            now: { now }
        )
        await backgroundAddFailureCoordinator.setEnabled(true)
        let backgroundAddFailureCompletion = CompletionProbe()
        let backgroundAddFailureTask = Task {
            let result = await backgroundAddFailureCoordinator.refreshAndDrain(
                expectedGraphID: "sample",
                fetchProjection: { raw }
            )
            await backgroundAddFailureCompletion.markCompleted()
            return result
        }
        await backgroundAddFailureCenter.waitForAddFailureStart()
        await backgroundAddFailureCenter.suspendCleanup()
        await backgroundAddFailureCenter.releaseHeldAddFailure()
        await backgroundAddFailureCenter.waitForManagedCleanupStart()
        try require(!(await backgroundAddFailureCompletion.hasCompleted()),
                    "A failed background add returned before managed cleanup drained")
        try require(await backgroundAddFailureCenter.storedIDs().contains(future.identifier),
                    "The held cleanup did not retain the old managed request while suspended")
        await backgroundAddFailureCenter.releaseSuspendedCleanup()
        try require(!(await backgroundAddFailureTask.value),
                    "A background refresh with a rejected OS add unexpectedly reported success")
        try require(await backgroundAddFailureCompletion.hasCompleted(),
                    "Failed background refresh completion was not recorded")
        try require(await backgroundAddFailureCenter.storedIDs() == [unrelatedID],
                    "Failed background add did not await managed-only cleanup")
        print("PASS: notification center add failures propagate through adapter/coordinator and background refresh drains managed alerts")

        let expirationCenter = ReminderCenterProbe(requests: [
            TaskReminderStoredNotification(
                identifier: future.identifier, graphId: future.graphId,
                taskUUID: future.taskUUID, pageId: future.pageId,
                fireDate: future.fireDate, trigger: future.trigger
            ),
            TaskReminderStoredNotification(
                identifier: unrelatedID, graphId: nil, taskUUID: nil,
                pageId: nil, fireDate: nil, trigger: nil
            )
        ])
        await expirationCenter.suspendCleanup()
        let expirationSuite = "TaskReminderBackgroundExpiration-\(UUID().uuidString)"
        let expirationDefaults = UserDefaults(suiteName: expirationSuite)!
        defer { expirationDefaults.removePersistentDomain(forName: expirationSuite) }
        let expirationCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: expirationCenter),
            defaults: expirationDefaults,
            now: { now }
        )
        let completionResults = BackgroundCompletionProbe()
        let networkTeardown = SuspendedAsyncProbe()
        let expirationGate = TaskReminderBackgroundCompletion(
            clearAndDrain: { await expirationCoordinator.clearAndDrain() },
            completion: { success in
                Task { await completionResults.record(success) }
            },
            afterExpiration: { await networkTeardown.run() }
        )
        expirationGate.expire(cancel: {
            MainActor.assumeIsolated { expirationGate.finish(success: true) }
        })
        await expirationCenter.waitForCleanupStart()
        try require(await completionResults.results().isEmpty,
                    "OS expiration completed before managed notification cleanup finished")
        expirationGate.finish(success: true)
        try require(await completionResults.results().isEmpty,
                    "A normal completion won while expiration cleanup was suspended")
        await expirationCenter.releaseSuspendedCleanup()
        await completionResults.waitForResult()
        try require(await completionResults.results() == [false],
                    "Expiration must complete exactly once with failure after managed cleanup")
        await networkTeardown.waitForStart()
        try require(await expirationCenter.storedIDs() == [unrelatedID],
                    "Expiration completion left managed requests pending or removed unrelated ones")
        await networkTeardown.release()
        print("PASS: OS expiration drains reminders before one false completion and slow network teardown")

        try await checkBackgroundOwnership(now: now)
        try await checkStoreCallbacksAndGraphMutation(now: now)

        let deniedCenter = ReminderCenterProbe(authorization: .denied)
        try require(await deniedCenter.authorizationStatus() == .denied,
                    "Injected denied authorization state was not preserved")
        let deniedAdapter = TaskReminderNotificationAdapter(center: deniedCenter)
        let deniedSuite = "TaskReminderDeniedRuntimeCheck-\(UUID().uuidString)"
        let deniedDefaults = UserDefaults(suiteName: deniedSuite)!
        defer { deniedDefaults.removePersistentDomain(forName: deniedSuite) }
        let deniedCoordinator = TaskReminderCoordinator(
            adapter: deniedAdapter, defaults: deniedDefaults, now: { now }
        )
        await deniedCoordinator.setEnabled(true)
        try require(!deniedCoordinator.isEnabled
                    && deniedCoordinator.statusForSettings.contains("Allow notifications"),
                    "Coordinator must leave reminders disabled and explain denied permission")
        let unreadyProjection = NativeTaskReminderProjection(
            graphId: "sample", ready: false, complete: true, tasks: projection.tasks
        )
        try require(TaskReminderPlan.make(from: unreadyProjection, now: now, timeZone: utc).items.isEmpty,
                    "An unready graph must not create task notifications")

        let capacityProjection = NativeTaskReminderProjection(
            graphId: "capacity", ready: true, complete: true,
            tasks: (0..<70).map { index in
                NativeTaskReminderProjection.Task(
                    uuid: "capacity-\(index)", pageId: "page",
                    temporal: .datetime(Int64(date("2030-01-01T00:00:00Z").timeIntervalSince1970 * 1_000) + Int64(index))
                )
            }
        )
        let capacityPlan = TaskReminderPlan.make(from: capacityProjection, now: now, timeZone: utc)
        try require(capacityPlan.items.count == 70,
                    "Planner should return all future tasks; OS capacity is applied during adapter reconciliation")
        let unrelatedRequests = (0..<20).map { index in
            TaskReminderStoredNotification(
                identifier: "another.app.notification.\(index)", graphId: nil,
                taskUUID: nil, pageId: nil, fireDate: nil, trigger: nil
            )
        }
        let capacityCenter = ReminderCenterProbe(requests: unrelatedRequests)
        await TaskReminderNotificationAdapter(center: capacityCenter).reconcile(capacityPlan, epoch: 1)
        let capacityIDs = await capacityCenter.storedIDs()
        let retainedUnrelated = Set(capacityIDs.filter { $0.hasPrefix("another.app.notification.") })
        let managedCount = capacityIDs.filter { $0.hasPrefix(TaskReminderPlan.managedPrefix) }.count
        try require(retainedUnrelated == Set(unrelatedRequests.map(\.identifier)),
                    "Pending-capacity reconciliation removed unrelated app notifications")
        try require(capacityIDs.count <= TaskReminderPlan.maximumPendingCount && managedCount == 44,
                    "Expected 44 managed plus 20 unrelated requests within the 64-request OS cap; got \(capacityIDs.count)")

        let permissionCenter = ReminderCenterProbe(authorization: .notDetermined)
        await permissionCenter.suspendAuthorization()
        let permissionSuite = "TaskReminderPermissionRace-\(UUID().uuidString)"
        let permissionDefaults = UserDefaults(suiteName: permissionSuite)!
        defer { permissionDefaults.removePersistentDomain(forName: permissionSuite) }
        let permissionCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: permissionCenter),
            defaults: permissionDefaults,
            now: { now }
        )
        let pendingEnable = Task { await permissionCoordinator.setEnabled(true) }
        await permissionCenter.waitForAuthorizationStart()
        await permissionCoordinator.invalidateForGraphMutation()
        await permissionCenter.releaseAuthorization(as: .authorized)
        await pendingEnable.value
        try require(permissionCoordinator.isEnabled,
                    "A routine graph invalidation discarded the user's Allow result")

        let disabledCenter = ReminderCenterProbe(authorization: .notDetermined)
        await disabledCenter.suspendAuthorization()
        let disabledSuite = "TaskReminderDisableRace-\(UUID().uuidString)"
        let disabledDefaults = UserDefaults(suiteName: disabledSuite)!
        defer { disabledDefaults.removePersistentDomain(forName: disabledSuite) }
        let disabledCoordinator = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: disabledCenter),
            defaults: disabledDefaults,
            now: { now }
        )
        let lateEnable = Task { await disabledCoordinator.setEnabled(true) }
        await disabledCenter.waitForAuthorizationStart()
        await disabledCoordinator.setEnabled(false)
        await disabledCenter.releaseAuthorization(as: .authorized)
        await lateEnable.value
        try require(!disabledCoordinator.isEnabled,
                    "A late Allow overrode the user's explicit reminder disable")
        if let mode = ProcessInfo.processInfo.environment["LOGSEQ_TASK_REMINDERS_OS_MODE"] {
            try await verifyOperatingSystem(mode: mode, response: raw)
        }
        print("PASS: denied permission and unready graph state cannot schedule; pending requests respect the OS capacity")
    }

    @MainActor
    private static func verifyOperatingSystem(mode: String, response: String) async throws {
        let center = UNUserNotificationCenter.current()
        let delegate = TaskReminderNotificationDelegate()
        center.delegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        let client = UserNotificationCenterClient(center: center)
        let adapter = TaskReminderNotificationAdapter(center: client)
        let coordinator = TaskReminderCoordinator(adapter: adapter, defaults: .standard)
        switch mode {
        case "authorize":
            await coordinator.setEnabled(true)
            let status = await client.authorizationStatus()
            print("OS_AUTHORIZATION_STATUS=\(status.rawValue)")
            if coordinator.isEnabled {
                let token = coordinator.beginRefresh()
                try require(await coordinator.reconcile(
                    futureDatedRuntimeResponse(response), expectedGraphID: "sample",
                    refreshToken: token
                ), "Actual OS grant failed to reconcile the core task projection")
                let basePending = await client.pending()
                let managedBeforeProbe = basePending.filter {
                    $0.identifier.hasPrefix(TaskReminderPlan.managedPrefix)
                }
                try require(!managedBeforeProbe.isEmpty,
                            "Real authorized notification center contains no core-projected managed reminder")
                let diagnostic = TaskReminderPlan.Item(
                    identifier: TaskReminderPlan.managedPrefix + "simulator-delivery-probe",
                    fireDate: .now.addingTimeInterval(20),
                    graphId: "sample", taskUUID: "simulator-delivery-probe", pageId: "page",
                    trigger: .instant
                )
                let plan = TaskReminderPlan.make(from: try decodeProjection(futureDatedRuntimeResponse(response)))
                await adapter.reconcile(
                    TaskReminderPlan(items: plan.items + [diagnostic],
                                     openTaskIdentifiers: plan.openTaskIdentifiers),
                    epoch: 10_000
                )
                let pending = await client.pending()
                try require(pending.contains(where: { $0.identifier == diagnostic.identifier }),
                            "Real notification center did not retain the short-delivery diagnostic")
                let osRequests = await center.pendingNotificationRequests()
                let diagnosticRequest = osRequests.first { $0.identifier == diagnostic.identifier }
                print("OS_DELEGATE_RETAINED=\(center.delegate === delegate)")
                print("OS_APP_STATE=\(UIApplication.shared.applicationState.rawValue)")
                let nextTrigger = (diagnosticRequest?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                print("OS_DIAGNOSTIC_NEXT_TRIGGER=\(String(describing: nextTrigger))")
                print("PASS: actual iOS notification permission is granted and managed requests are pending")
                try await Task.sleep(for: .seconds(25))
                let delivered = await center.deliveredNotifications()
                let deliveredDiagnostic = delivered.first {
                    $0.request.identifier == diagnostic.identifier
                }
                try require(deliveredDiagnostic?.request.content.title == "Task reminder"
                            && deliveredDiagnostic?.request.content.body == "A task is due.",
                            "iOS did not deliver the generic diagnostic notification in the same app launch")
                print("PASS: iOS delivered the generic diagnostic through the production foreground delegate")
            } else {
                try require(status == .denied,
                            "OS permission probe left reminders disabled without a denied authorization status")
                print("PASS: actual iOS notification permission denial leaves opt-in disabled")
            }
        case "refresh":
            await coordinator.refreshPermissionStatus()
            let status = await client.authorizationStatus()
            try require(status == .denied && !coordinator.isEnabled,
                        "Revoked iOS permission did not disable the stored app opt-in")
            try require(!(await client.pending()).contains(where: {
                $0.identifier.hasPrefix(TaskReminderPlan.managedPrefix)
            }), "Revoked iOS permission left Logseq reminders pending")
            print("PASS: actual iOS permission revocation clears managed pending reminders")
        case "revocation":
            await coordinator.refreshPermissionStatus()
            try require(!coordinator.isEnabled,
                        "Revocation probe must start with the app-level opt-in disabled")
            try await openNotificationSettingsAndReturn()
            let grantedStatus = await client.authorizationStatus()
            try require(grantedStatus == .authorized || grantedStatus == .provisional,
                        "Notification settings did not grant authorization for the revocation probe")
            await coordinator.setEnabled(true)
            try require(coordinator.isEnabled,
                        "The app could not enable reminders after notification permission was granted")
            let managedPending = await client.pending().filter {
                $0.identifier.hasPrefix(TaskReminderPlan.managedPrefix)
            }
            try require(!managedPending.isEmpty,
                        "The revocation probe did not schedule managed notifications before revoking")
            try await openNotificationSettingsAndReturn()
            await coordinator.refreshPermissionStatus()
            let revokedStatus = await client.authorizationStatus()
            try require(revokedStatus == .denied && !coordinator.isEnabled,
                        "Revoking notification permission did not disable the stored app opt-in")
            try require(!(await client.pending()).contains(where: {
                $0.identifier.hasPrefix(TaskReminderPlan.managedPrefix)
            }), "Revocation left managed notifications pending")
            print("PASS: revoking real iOS notification authorization disables opt-in and clears pending alerts")
        case "delivered":
            let delivered = await center.deliveredNotifications()
            let pending = await client.pending()
            print("OS_PENDING_IDENTIFIERS=\(pending.map(\.identifier).sorted())")
            print("OS_DELIVERED_IDENTIFIERS=\(delivered.map { $0.request.identifier }.sorted())")
            let diagnostic = delivered.first {
                $0.request.identifier == TaskReminderPlan.managedPrefix + "simulator-delivery-probe"
            }
            try require(diagnostic != nil,
                        "The actual iOS notification center did not report the delivered diagnostic")
            try require(diagnostic?.request.content.title == "Task reminder"
                        && diagnostic?.request.content.body == "A task is due.",
                        "Delivered lock-screen notification was not generic and privacy-safe")
            print("PASS: actual iOS notification center reports the generic diagnostic as delivered")
        default:
            throw failure("Unknown OS notification probe mode: \(mode)")
        }
    }

    private static func decodeProjection(_ response: String) throws -> NativeTaskReminderProjection {
        try JSONDecoder().decode(
            TaskReminderRPCEnvelope<NativeTaskReminderProjection>.self,
            from: Data(response.utf8)
        ).result
    }

    private static func futureDatedRuntimeResponse(_ response: String) -> String {
        response.replacingOccurrences(
            of: #""timestampMs":1794484800000"#,
            with: #""timestampMs":\#(Int64(Date.now.timeIntervalSince1970 * 1_000) + 86_400_000)"#
        )
    }

    private static func openNotificationSettingsAndReturn() async throws {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString),
              await UIApplication.shared.open(url) else {
            throw failure("iOS could not open this app's notification settings")
        }
        print("OS_NOTIFICATION_SETTINGS_OPENED=true")
        for _ in 0..<80 {
            let state = await UIApplication.shared.applicationState
            if state != .active { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard await UIApplication.shared.applicationState != .active else {
            throw failure("iOS notification settings did not foreground; cannot perform revocation probe")
        }
        for _ in 0..<240 {
            if await UIApplication.shared.applicationState == .active { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw failure("Return to the runtime-check app after changing notification settings")
    }



    @MainActor
    private static func checkStoreCallbacksAndGraphMutation(now: Date) async throws {
        let raw = #"{"result":{"graphId":"sample","ready":true,"complete":true,"tasks":[{"uuid":"owned","pageId":"page","temporal":{"kind":"datetime","timestampMs":4070908800000}}]}}"#
        let snapshot = #"{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Synthetic","selectedGraphId":"sample","isGraphUnlocked":true},"error":null}"#
        let projection = try JSONDecoder().decode(
            TaskReminderEnvelope<NativeTaskReminderProjection>.self, from: Data(raw.utf8)
        ).result
        let plan = TaskReminderPlan.make(from: projection, now: now)
        for succeeds in [true, false] {
            let suite = "TaskReminderStoreCallback-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let center = ReminderCenterProbe()
            let reminders = TaskReminderCoordinator(
                adapter: TaskReminderNotificationAdapter(center: center), defaults: defaults, now: { now }
            )
            await reminders.setEnabled(true)
            if succeeds { await center.suspendAdds() }
            else {
                try require(await reminders.reconcile(raw, expectedGraphID: "sample",
                                                      refreshToken: reminders.beginRefresh()),
                            "Could not seed the failed-sync cleanup check")
                await center.suspendCleanup()
            }
            var callbacks = 0
            var independentRefreshes = 0
            // Exercise the real async LogseqStore.configure -> core executor ->
            // Store.apply -> responseObserver path. All RPC/transport data is
            // synthetic; no graph, network, credentials, or real core is used.
            let store = LogseqStore(call: { _ in snapshot }, responseObserver: { _ in
                callbacks += 1
                TaskReminderBackgroundAttempt.refreshAfterCoreResponse {
                    independentRefreshes += 1
                    _ = reminders.beginRefresh()
                }
            })
            let finished = CompletionProbe()
            let attempt = TaskReminderBackgroundAttempt()
            let background = Task {
                let result = await attempt.run(reminders: reminders, sync: GraphSyncCoordinator(),
                                               synchronizeGraph: {
                    await store.configureAndSelectGraph(baseURL: "https://example.invalid",
                                                        token: "synthetic", selectedGraphID: "sample")
                    await store.syncPendingForBackground()
                    return succeeds ? "sample" : nil
                }, fetchProjection: { _ in raw })
                await finished.markCompleted()
                return result
            }
            if succeeds { await center.waitForAddStart() }
            // Seeding the plan performs an empty cleanup too. Wait for this
            // failure's managed removal, rather than that earlier empty call.
            else { await center.waitForManagedCleanupStart() }
            try require(callbacks >= 2 && independentRefreshes == 0,
                        "Real store/child sync callbacks superseded their own background attempt")
            try require(!(await finished.hasCompleted()),
                        "Background completed before its final add/cleanup drained")
            if succeeds { await center.releaseSuspendedAdd() }
            else { await center.releaseSuspendedCleanup() }
            try require(await background.value == succeeds,
                        "Real store callback flow lost the final background result")
            let remaining = await center.storedIDs()
            try require(succeeds ? remaining == Set(plan.items.map(\.identifier)) : remaining.isEmpty,
                        "Real store callback flow failed final reminder reconciliation/cleanup")
            // An independent response after the context exits reserves a fresh
            // epoch; inherited child contexts must not suppress it forever.
            await store.configureAndSelectGraph(baseURL: "https://example.invalid",
                                                token: "", selectedGraphID: "sample")
            try require(independentRefreshes == 1, "Completed sync suppressed a later response")
        }
        print("PASS: real async store and child sync callbacks coalesce; background success/failure await final add/cleanup")

        let suite = "TaskReminderGraphMutationBarrier-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterProbe()
        let reminders = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: center), defaults: defaults, now: { now }
        )
        await reminders.setEnabled(true)
        try require(await reminders.reconcile(raw, expectedGraphID: "sample",
                                              refreshToken: reminders.beginRefresh()),
                    "Could not seed old graph")
        await center.suspendCleanup()
        let effect = SuspendedAsyncProbe()
        let mutation = Task {
            try await reminders.withGraphMutation {
                try require(await center.storedIDs().isEmpty,
                            "Graph effect started before old-scope requests were cleared")
                await effect.run()
            }
        }
        await center.waitForManagedCleanupStart()
        let duringCleanup = reminders.beginRefresh()
        try require(!(await reminders.reconcile(raw, expectedGraphID: "sample", refreshToken: duringCleanup)),
                    "Old graph wrote while mandatory cleanup was suspended")
        await center.releaseSuspendedCleanup()
        await effect.waitForStart()
        let duringEffect = reminders.beginRefresh()
        try require(!(await reminders.reconcile(raw, expectedGraphID: "sample", refreshToken: duringEffect)),
                    "Old graph wrote while the actual graph switch was suspended")
        await effect.release()
        try await mutation.value
        try require(!(await reminders.reconcile(raw, expectedGraphID: "sample", refreshToken: duringEffect)),
                    "An old-scope callback survived the graph-switch barrier")
        let newGraph = raw.replacingOccurrences(of: "sample", with: "new-graph")
        try require(await reminders.reconcile(newGraph, expectedGraphID: "new-graph",
                                              refreshToken: reminders.beginRefresh()),
                    "Graph barrier suppressed a legitimate new-scope plan")
        do {
            try await reminders.withGraphMutation { throw ReminderCenterProbeError.forcedAddFailure }
        } catch ReminderCenterProbeError.forcedAddFailure {}
        try require(await reminders.reconcile(newGraph, expectedGraphID: "new-graph",
                                              refreshToken: reminders.beginRefresh()),
                    "A failed graph effect did not release its barrier")
        // Match the runtime callers: leave the barrier, then report a failed
        // graph operation through the same callback helper. Failure must request
        // a new authoritative projection without triggering success navigation.
        var recoveryTask: Task<Bool, Never>?
        var successRoutes = 0
        var recoveryProjection = newGraph
        reminders.onGraphMutationCompleted = { successRoutes += 1 }
        reminders.onCoreMutation = {
            let response = recoveryProjection
            recoveryTask = Task {
                await reminders.refreshAndDrain(expectedGraphID: "new-graph") { response }
            }
        }
        let failedSwitch = await reminders.withGraphMutation { false }
        reminders.graphMutationDidFinish(succeeded: failedSwitch)
        let validRecovery = try require(recoveryTask, "Failed graph caller did not request a fresh projection")
        try require(await validRecovery.value,
                    "Failed graph caller did not restore the still-valid graph plan")
        try require(successRoutes == 0, "Failed graph recovery invoked success navigation")
        recoveryProjection = #"{"result":{"graphId":"new-graph","ready":false,"complete":false,"tasks":[]}}"#
        recoveryTask = nil
        let unavailableSwitch = await reminders.withGraphMutation { false }
        reminders.graphMutationDidFinish(succeeded: unavailableSwitch)
        let invalidRecovery = try require(recoveryTask, "Unavailable graph did not request validation")
        try require(!(await invalidRecovery.value), "Failed graph recovery accepted unavailable core state")
        try require(await center.storedIDs().isEmpty, "Unavailable graph recovery restored stale reminders")
        print("PASS: graph mutation fences old callbacks through cleanup/effect, clears before switching, and releases on failure")
    }

    @MainActor
    private static func checkBackgroundOwnership(now: Date) async throws {
        let raw = #"{"result":{"graphId":"sample","ready":true,"complete":true,"tasks":[{"uuid":"owned","pageId":"page","temporal":{"kind":"datetime","timestampMs":4070908800000}}]}}"#
        let projection = try JSONDecoder().decode(
            TaskReminderEnvelope<NativeTaskReminderProjection>.self, from: Data(raw.utf8)
        ).result
        let plan = TaskReminderPlan.make(from: projection, now: now)
        let item = plan.items[0]
        let suite = "TaskReminderBackgroundOwnership-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterProbe()
        let adapter = TaskReminderNotificationAdapter(center: center)
        let reminders = TaskReminderCoordinator(adapter: adapter, defaults: defaults, now: { now })
        await reminders.setEnabled(true)

        // Exercise the exact helper used by LogseqApp across its network wait.
        for syncSucceeds in [false, true] {
            let sync = GraphSyncCoordinator()
            let gate = SuspendedAsyncProbe()
            let attempt = TaskReminderBackgroundAttempt()
            let background = Task {
                await attempt.run(reminders: reminders, sync: sync, synchronizeGraph: {
                    await gate.run()
                    return syncSucceeds ? "sample" : nil
                }, fetchProjection: { _ in raw })
            }
            await gate.waitForStart()
            let newerToken = reminders.beginRefresh()
            try require(await reminders.reconcile(raw, expectedGraphID: "sample", refreshToken: newerToken),
                        "New foreground plan did not complete")
            await gate.release()
            try require(!(await background.value), "A superseded sync reported reminder success")
            try require(await center.storedIDs() == [item.identifier],
                        "Old sync failure/success erased a newer foreground plan")
            await attempt.expireAndDrain()
            await attempt.awaitExpiredNetworkTask()
            try require(await center.storedIDs() == [item.identifier],
                        "Late expiration cleared a completed newer plan")
        }

        // An expiration while the old network call is still suspended must
        // preserve newer scene work and must await only the captured old task.
        let sync = GraphSyncCoordinator()
        let oldGate = SuspendedAsyncProbe()
        let oldAttempt = TaskReminderBackgroundAttempt()
        let old = Task {
            await oldAttempt.run(reminders: reminders, sync: sync, synchronizeGraph: {
                await oldGate.run()
                return nil
            }, fetchProjection: { _ in raw })
        }
        await oldGate.waitForStart()
        try require(await reminders.reconcile(raw, expectedGraphID: "sample",
                                              refreshToken: reminders.beginRefresh()),
                    "Foreground scene plan failed")
        await oldAttempt.expireAndDrain()
        try require(await center.storedIDs() == [item.identifier],
                    "An old in-flight expiration cleared a newer scene plan")
        await oldGate.release()
        try require(!(await old.value), "Expired background succeeded")
        let newGate = SuspendedAsyncProbe()
        let newAttempt = TaskReminderBackgroundAttempt()
        let newer = Task {
            await newAttempt.run(reminders: reminders, sync: sync, synchronizeGraph: {
                await newGate.run()
                return Task.isCancelled ? nil : "sample"
            }, fetchProjection: { _ in raw })
        }
        await newGate.waitForStart()
        await oldAttempt.expireAndDrain()
        await oldAttempt.awaitExpiredNetworkTask()
        await newGate.release()
        try require(await newer.value, "Old expiration/teardown canceled a newer sync generation")

        // Two OS budgets share one operation. Expiring either first or second
        // waiter must keep the other alive; expiring the last must drain the
        // first operation's epoch, even when the last caller never ran it.
        for expireFirst in [true, false] {
            let sharedSync = GraphSyncCoordinator()
            let gate = SuspendedAsyncProbe()
            let firstAttempt = TaskReminderBackgroundAttempt()
            let secondAttempt = TaskReminderBackgroundAttempt()
            let first = Task {
                await firstAttempt.run(reminders: reminders, sync: sharedSync, synchronizeGraph: {
                    await gate.run()
                    return Task.isCancelled ? nil : "sample"
                }, fetchProjection: { _ in raw })
            }
            await gate.waitForStart()
            let second = Task {
                await secondAttempt.run(reminders: reminders, sync: sharedSync,
                                        synchronizeGraph: { throwUnexpectedSharedExecution() },
                                        fetchProjection: { _ in raw })
            }
            // Let the second waiter enter the actor while the shared operation
            // is held at a deterministic continuation.
            try await Task.sleep(for: .milliseconds(20))
            await (expireFirst ? firstAttempt : secondAttempt).expireAndDrain()
            await gate.release()
            let firstResult = await first.value
            let secondResult = await second.value
            try require(firstResult == !expireFirst && secondResult == expireFirst,
                        "Expiring one coalesced waiter canceled the remaining budget")
            await (expireFirst ? firstAttempt : secondAttempt).awaitExpiredNetworkTask()
        }
        let sharedSync = GraphSyncCoordinator()
        let sharedGate = SuspendedAsyncProbe()
        let firstAttempt = TaskReminderBackgroundAttempt()
        let secondAttempt = TaskReminderBackgroundAttempt()
        let sharedFirst = Task {
            await firstAttempt.run(reminders: reminders, sync: sharedSync, synchronizeGraph: {
                await sharedGate.run()
                return "sample"
            }, fetchProjection: { _ in raw })
        }
        await sharedGate.waitForStart()
        let sharedSecond = Task {
            await secondAttempt.run(reminders: reminders, sync: sharedSync,
                                    synchronizeGraph: { throwUnexpectedSharedExecution() },
                                    fetchProjection: { _ in raw })
        }
        try await Task.sleep(for: .milliseconds(20))
        await firstAttempt.expireAndDrain()
        await secondAttempt.expireAndDrain()
        try require(await center.storedIDs().isEmpty,
                    "Last coalesced expiration failed to clear the shared operation's alerts")
        await sharedGate.release()
        let sharedFirstResult = await sharedFirst.value
        let sharedSecondResult = await sharedSecond.value
        try require(!sharedFirstResult && !sharedSecondResult,
                    "Expired coalesced callers reported success")
        await secondAttempt.awaitExpiredNetworkTask()

        // Mandatory invalidation can enter the adapter after a newer plan has
        // already committed, or after only a disabled/no-op epoch advance.
        let newerToken = reminders.beginRefresh()
        try require(await reminders.reconcile(raw, expectedGraphID: "sample", refreshToken: newerToken),
                    "Valid plan failed before delayed mandatory cleanup")
        await adapter.invalidate(to: newerToken - 1)
        try require(await center.storedIDs() == [item.identifier],
                    "Delayed mandatory cleanup erased a newer completed plan")
        adapter.advance(to: newerToken + 2)
        await adapter.invalidate(to: newerToken + 1)
        try require(await center.storedIDs().isEmpty,
                    "A no-op epoch suppressed mandatory cleanup")
        print("PASS: production background helper preserves newer plans, scopes expiration/teardown, and handles both coalesced waiter orders")

        // Expiration races a held notification add and held managed cleanup.
        // Completion must remain exactly once and after the writer has drained.
        let drainCenter = ReminderCenterProbe()
        await drainCenter.suspendAdds()
        let drainReminders = TaskReminderCoordinator(
            adapter: TaskReminderNotificationAdapter(center: drainCenter), defaults: defaults, now: { now }
        )
        let drainAttempt = TaskReminderBackgroundAttempt()
        let completions = BackgroundCompletionProbe()
        let completion = TaskReminderBackgroundCompletion(
            clearAndDrain: { await drainAttempt.expireAndDrain() },
            completion: { value in Task { await completions.record(value) } },
            afterExpiration: { await drainAttempt.awaitExpiredNetworkTask() }
        )
        let draining = Task {
            let value = await drainAttempt.run(reminders: drainReminders, sync: GraphSyncCoordinator(),
                                               synchronizeGraph: { "sample" }, fetchProjection: { _ in raw })
            completion.finish(success: value)
            return value
        }
        await drainCenter.waitForAddStart()
        completion.expire(cancel: { draining.cancel() })
        await drainCenter.suspendCleanup()
        try require(await completions.results().isEmpty,
                    "Expiration completed while its notification add was suspended")
        await drainCenter.releaseSuspendedAdd()
        await drainCenter.waitForCleanupStart()
        try require(await completions.results().isEmpty,
                    "Expiration completed before serialized cleanup drained")
        await drainCenter.releaseSuspendedCleanup()
        _ = await draining.value
        await completions.waitForResult()
        completion.finish(success: true)
        completion.expire(cancel: {})
        let completedValues = await completions.results()
        let remainingIDs = await drainCenter.storedIDs()
        try require(completedValues == [false] && remainingIDs.isEmpty,
                    "Expiration did not finish exactly once after draining owned writes")
        print("PASS: production expiration helper awaits held writes and cleanup before exactly one OS completion")

        let normalProbe = SynchronousBackgroundCompletionProbe()
        let normalCompletion = TaskReminderBackgroundCompletion(
            clearAndDrain: {},
            completion: { normalProbe.record($0) }
        )
        normalCompletion.finish(success: true)
        normalCompletion.finish(success: false)
        normalCompletion.expire(cancel: { normalProbe.recordCancel() })
        let normalResult = normalProbe.snapshot()
        try require(normalResult.values == [true],
                    "Repeated finish or post-finish expiration changed the successful OS completion")
        try require(normalResult.cancelCount == 0,
                    "Post-finish expiration canceled work")
        print("PASS: normal success completes once; repeated finish and later expiration are no-ops")
    }

    private static func throwUnexpectedSharedExecution() -> String? {
        fatalError("A coalesced background caller executed a second graph sync")
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let result = formatter.date(from: value) else { fatalError("Invalid test date: \(value)") }
        return result
    }

    @discardableResult
    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TaskReminderRuntimeCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#if !LOGSEQ_LINKED_CORE
@_cdecl("logseq_initialize")
func unexpectedTaskReminderCoreInitialization() { fatalError("Unexpected native core initialization") }
#endif
