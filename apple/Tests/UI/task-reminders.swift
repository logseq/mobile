import Foundation
import UserNotifications
import UIKit
@testable import Logseq

private struct TaskReminderEnvelope<Value: Decodable>: Decodable {
    let result: Value
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
    private var shouldSuspendCleanup = false
    private var cleanupStarted = false
    private var cleanupStartWaiters: [CheckedContinuation<Void, Never>] = []
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
        await reconcile.value
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
