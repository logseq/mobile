import Foundation
import CryptoKit
import UserNotifications
import os

func taskReminderLocalization(for identifier: String) -> String {
    let language = Locale.Language(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
    guard let code = language.languageCode?.identifier else { return "en" }
    if code == "zh" { return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
    return code
}

private func taskReminderLocalized(_ key: String) -> String {
    let setting = UserDefaults.standard.string(forKey: "logseq.language") ?? "system"
    let requested = setting == "system" ? Locale.preferredLanguages.first ?? "en" : setting
    let localization = taskReminderLocalization(for: requested)
    if let path = Bundle.module.url(forResource: localization, withExtension: "lproj"),
       let languageBundle = Bundle(url: path) {
        return languageBundle.localizedString(forKey: key, value: key, table: nil)
    }
    return Bundle.module.localizedString(forKey: key, value: key, table: nil)
}

@MainActor
final class TaskReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var openTask: ((String, String, String) async -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let options: UNNotificationPresentationOptions = notification.request.identifier.hasPrefix(TaskReminderPlan.managedPrefix)
            ? [.banner, .list, .sound]
            : []
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              request.identifier.hasPrefix(TaskReminderPlan.managedPrefix),
              let graphId = request.content.userInfo["graphId"] as? String,
              let taskUUID = request.content.userInfo["taskUUID"] as? String,
              let pageId = request.content.userInfo["pageId"] as? String,
              !graphId.isEmpty, !taskUUID.isEmpty, !pageId.isEmpty
        else {
            completionHandler()
            return
        }
        // Default taps foreground the app. Acknowledge the response after queuing
        // only its immutable route; restoration and validation remain on MainActor.
        Task { @MainActor [weak self] in
            await self?.openTask?(graphId, taskUUID, pageId)
        }
        completionHandler()
    }
}

struct NativeTaskReminderProjection: Decodable, Sendable {
    let graphId: String?
    let ready: Bool
    let complete: Bool
    let tasks: [Task]

    struct Task: Decodable, Sendable {
        let uuid: String
        let pageId: String
        let temporal: Temporal
    }

    enum Temporal: Decodable, Sendable {
        case datetime(Int64)
        case date(Int)

        private enum CodingKeys: String, CodingKey { case kind, timestampMs, day }
        private enum Kind: String, Decodable { case datetime, date }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .datetime: self = .datetime(try values.decode(Int64.self, forKey: .timestampMs))
            case .date: self = .date(try values.decode(Int.self, forKey: .day))
            }
        }
    }
}

struct TaskReminderCurrentContext: Equatable, Sendable {
    let graphId: String
    let taskUUID: String
    let pageId: String
}

enum TaskReminderRouteResolver {
    static func resolve(
        graphId: String,
        taskUUID: String,
        in projection: NativeTaskReminderProjection
    ) -> TaskReminderCurrentContext? {
        guard projection.ready, projection.complete, projection.graphId == graphId,
              let task = projection.tasks.first(where: { $0.uuid == taskUUID })
        else { return nil }
        return TaskReminderCurrentContext(
            graphId: graphId,
            taskUUID: task.uuid,
            pageId: task.pageId
        )
    }
}

struct TaskReminderPlan: Sendable, Equatable {
    enum Trigger: Sendable, Equatable {
        case instant
        case localDate(Int)

        static func from(_ components: DateComponents) -> Self? {
            if let zone = components.timeZone {
                return zone.secondsFromGMT() == 0 ? .instant : nil
            }
            guard components.calendar?.identifier == .gregorian,
                  let year = components.year, let month = components.month,
                  let day = components.day,
                  (1_000...9_999).contains(year), (1...12).contains(month),
                  (1...31).contains(day),
                  components.hour == 9, components.minute == 0,
                  components.second == 0,
                  components.isValidDate(in: Calendar(identifier: .gregorian))
            else { return nil }
            return .localDate(year * 10_000 + month * 100 + day)
        }
    }

    struct Item: Sendable, Equatable {
        let identifier: String
        let fireDate: Date
        let graphId: String
        let taskUUID: String
        let pageId: String
        let trigger: Trigger

        var triggerTimeZone: TimeZone {
            switch trigger {
            case .instant: .gmt
            case .localDate: .autoupdatingCurrent
            }
        }

        var triggerDateComponents: DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            switch trigger {
            case .instant:
                calendar.timeZone = .gmt
                var components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fireDate
                )
                components.calendar = calendar
                components.timeZone = .gmt
                return components
            case .localDate(let day):
                calendar.timeZone = .autoupdatingCurrent
                // Keep the calendar day and 09:00, without pinning the request to
                // the zone that was current when this plan was computed.
                return DateComponents(
                    calendar: calendar,
                    year: day / 10_000, month: (day / 100) % 100, day: day % 100,
                    hour: 9, minute: 0, second: 0
                )
            }
        }
    }
    let items: [Item]
    let openTaskIdentifiers: Set<String>

    static let maximumPendingCount = 64
    static let managedPrefix = "com.logseq.task-reminder."

    static func make(
        from projection: NativeTaskReminderProjection,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> Self {
        guard projection.ready, projection.complete,
              let graphId = projection.graphId, !graphId.isEmpty else {
            return Self(items: [], openTaskIdentifiers: [])
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let planned = projection.tasks.compactMap { task -> Item? in
            let fireDate: Date
            let trigger: Trigger
            switch task.temporal {
            case .datetime(let timestampMs):
                fireDate = Date(timeIntervalSince1970: Double(timestampMs) / 1_000)
                trigger = .instant
            case .date(let day):
                guard (10_000_000...99_991_231).contains(day) else { return nil }
                let year = day / 10_000
                let month = (day / 100) % 100
                let date = day % 100
                guard let localDay = calendar.date(from: DateComponents(year: year, month: month, day: date))
                else { return nil }
                let checkedDay = calendar.dateComponents([.year, .month, .day], from: localDay)
                guard checkedDay.year == year, checkedDay.month == month, checkedDay.day == date,
                      let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: localDay)
                else { return nil }
                fireDate = nineAM
                trigger = .localDate(day)
            }
            // Overdue work is intentionally omitted; adding an already-past UN trigger can
            // create a surprise immediate alert during a graph refresh.
            guard fireDate > now else { return nil }
            return Item(
                identifier: identifier(graphId: graphId, taskUUID: task.uuid),
                fireDate: fireDate,
                graphId: graphId,
                taskUUID: task.uuid,
                pageId: task.pageId,
                trigger: trigger
            )
        }
        return Self(items: planned.sorted {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            return $0.identifier < $1.identifier
        },
            openTaskIdentifiers: Set(projection.tasks.map {
                identifier(graphId: graphId, taskUUID: $0.uuid)
            }))
    }

    fileprivate static func identifier(graphId: String, taskUUID: String) -> String {
        let digest = SHA256.hash(data: Data((graphId + "\u{0}" + taskUUID).utf8))
        return managedPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}

protocol TaskReminderNotificationStoring: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func advance(to epoch: UInt64)
    func invalidate(to epoch: UInt64) async
    func invalidateIfCurrent(to epoch: UInt64) async
    @discardableResult
    func reconcile(_ plan: TaskReminderPlan, epoch: UInt64) async -> Bool
}

struct TaskReminderStoredNotification: Sendable {
    let identifier: String
    let graphId: String?
    let taskUUID: String?
    let pageId: String?
    let fireDate: Date?
    let trigger: TaskReminderPlan.Trigger?
}

protocol TaskReminderCenterClient: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pending() async -> [TaskReminderStoredNotification]
    func delivered() async -> [TaskReminderStoredNotification]
    func add(_ item: TaskReminderPlan.Item) async throws
    func removePending(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
}

actor UserNotificationCenterClient: TaskReminderCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pending() async -> [TaskReminderStoredNotification] {
        await center.pendingNotificationRequests().map(Self.record)
    }

    func delivered() async -> [TaskReminderStoredNotification] {
        await center.deliveredNotifications().map { Self.record($0.request) }
    }

    func add(_ item: TaskReminderPlan.Item) async throws {
        let content = UNMutableNotificationContent()
        content.title = taskReminderLocalized("Task reminder")
        content.body = taskReminderLocalized("A task is due.")
        content.userInfo = ["graphId": item.graphId, "taskUUID": item.taskUUID, "pageId": item.pageId]
        content.categoryIdentifier = "LOGSEQ_TASK_REMINDER"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: item.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: item.triggerDateComponents, repeats: false)
        )
        try await center.add(request)
    }

    func removePending(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private static func record(_ request: UNNotificationRequest) -> TaskReminderStoredNotification {
        let content = request.content
        let trigger = request.trigger as? UNCalendarNotificationTrigger
        return TaskReminderStoredNotification(
            identifier: request.identifier,
            graphId: content.userInfo["graphId"] as? String,
            taskUUID: content.userInfo["taskUUID"] as? String,
            pageId: content.userInfo["pageId"] as? String,
            fireDate: trigger?.nextTriggerDate(),
            trigger: trigger.flatMap { TaskReminderPlan.Trigger.from($0.dateComponents) }
        )
    }
}

actor TaskReminderNotificationAdapter: TaskReminderNotificationStoring {
    private let center: any TaskReminderCenterClient
    // Refresh requests fence in-flight writes synchronously, before debounce or
    // a core read can suspend the caller. Center operations remain serialized.
    private let epochFence = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var latestEpoch: UInt64 { epochFence.withLock { $0 } }
    private var writeTail: Task<Void, Never>?
    private var reconciliationDrains: [UInt64: Task<Void, Never>] = [:]
    private var lastCompletedPlanEpoch: UInt64 = 0

    init(center: any TaskReminderCenterClient = UserNotificationCenterClient()) { self.center = center }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization()
    }

    nonisolated func advance(to epoch: UInt64) {
        epochFence.withLock { $0 = max($0, epoch) }
    }

    func invalidate(to epoch: UInt64) async {
        advance(to: epoch)
        await enqueue { [self] in
            // A newer request alone cannot suppress mandatory opt-out/scope
            // cleanup. A newer fully committed authoritative plan can.
            await removeManagedRequests(unlessPlanAfter: epoch)
        }.value
    }

    func invalidateIfCurrent(to epoch: UInt64) async {
        guard epoch == latestEpoch else {
            // Join only this attempt's write. A stale network read that never
            // wrote must not wait on an unrelated newer foreground add.
            await reconciliationDrains[epoch]?.value
            return
        }
        await enqueue { [self] in await removeManagedRequests(ifCurrent: epoch) }.value
    }

    @discardableResult
    func reconcile(_ plan: TaskReminderPlan, epoch: UInt64) async -> Bool {
        guard epoch >= latestEpoch else { return false }
        advance(to: epoch)
        let write = enqueue { [self] in await reconcileNow(plan, epoch: epoch) }
        reconciliationDrains[epoch] = Task { _ = await write.value }
        let result = await write.value
        reconciliationDrains[epoch] = nil
        return result
    }

    private func enqueue<Result: Sendable>(
        _ operation: @escaping @Sendable () async -> Result
    ) -> Task<Result, Never> {
        let previous = writeTail
        let next = Task {
            await previous?.value
            return await operation()
        }
        writeTail = Task { _ = await next.value }
        return next
    }

    private func reconcileNow(_ plan: TaskReminderPlan, epoch: UInt64) async -> Bool {
        guard epoch == latestEpoch else { return false }
        let allPending = await center.pending()
        let pending = allPending.filter {
            $0.identifier.hasPrefix(TaskReminderPlan.managedPrefix)
        }
        let unrelatedPendingCount = allPending.count - pending.count
        let availableManagedCapacity = max(
            0,
            TaskReminderPlan.maximumPendingCount - unrelatedPendingCount
        )
        let desiredItems = Array(plan.items.prefix(availableManagedCapacity))
        let stalePendingIDs = pending.compactMap { request -> String? in
            guard let planItem = desiredItems.first(where: { $0.identifier == request.identifier }) else {
                return request.identifier
            }
            guard let nextDate = request.fireDate,
                  abs(nextDate.timeIntervalSince(planItem.fireDate)) < 2,
                  request.graphId == planItem.graphId,
                  request.taskUUID == planItem.taskUUID,
                  request.pageId == planItem.pageId,
                  request.trigger == planItem.trigger else {
                return request.identifier
            }
            return nil
        }
        await center.removePending(stalePendingIDs)
        let delivered = await center.delivered()
        let futureTaskIdentifiers = Set(plan.items.map(\.identifier))
        let staleDeliveredIDs = delivered.compactMap { request -> String? in
            guard request.identifier.hasPrefix(TaskReminderPlan.managedPrefix) else { return nil }
            guard let graph = request.graphId, !graph.isEmpty,
                  let task = request.taskUUID, !task.isEmpty,
                  let page = request.pageId, !page.isEmpty,
                  request.identifier == TaskReminderPlan.identifier(graphId: graph, taskUUID: task),
                  plan.openTaskIdentifiers.contains(request.identifier),
                  !futureTaskIdentifiers.contains(request.identifier)
            else { return request.identifier }
            return nil
        }
        await center.removeDelivered(staleDeliveredIDs)

        for item in desiredItems {
            guard epoch == latestEpoch else { return false }
            if pending.contains(where: { $0.identifier == item.identifier }),
               !stalePendingIDs.contains(item.identifier) {
                continue
            }
            do {
                try await center.add(item)
            } catch {
                logger.error("Could not schedule a task reminder: \(error.localizedDescription)")
                return false
            }
            guard epoch == latestEpoch else {
                await center.removePending([item.identifier])
                await center.removeDelivered([item.identifier])
                return false
            }
        }
        guard epoch == latestEpoch else { return false }
        lastCompletedPlanEpoch = epoch
        return true
    }

    private func removeManagedRequests(
        ifCurrent epoch: UInt64? = nil,
        unlessPlanAfter mandatoryEpoch: UInt64? = nil
    ) async {
        if let epoch, epoch != latestEpoch { return }
        if let mandatoryEpoch, lastCompletedPlanEpoch > mandatoryEpoch { return }
        let pending = await center.pending()
            .map(\.identifier).filter { $0.hasPrefix(TaskReminderPlan.managedPrefix) }
        let delivered = await center.delivered()
            .map(\.identifier).filter { $0.hasPrefix(TaskReminderPlan.managedPrefix) }
        await center.removePending(pending)
        await center.removeDelivered(delivered)
    }
}

@MainActor
final class TaskReminderCoordinator {
    private let adapter: any TaskReminderNotificationStoring
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var epoch: UInt64 = 0
    private var scopeEpoch: UInt64 = 0
    private var graphMutationDepth = 0
    // Permission consent can outlive an ordinary foreground graph refresh. Only a
    // newer opt-in choice or an account/API reset supersedes that user intent.
    private var enableIntentEpoch: UInt64 = 0
    private var statusMessageKey: String?
    var onSettingsChanged: (() -> Void)?
    var onGraphMutationCompleted: (() -> Void)?
    var onCoreMutation: (() -> Void)?

    static let enabledDefaultsKey = "logseq.taskReminders.enabled"

    init(
        adapter: any TaskReminderNotificationStoring = TaskReminderNotificationAdapter(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.adapter = adapter
        self.defaults = defaults
        self.now = now
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledDefaultsKey) }
    var currentEpoch: UInt64 { epoch }
    var currentScopeEpoch: UInt64 { scopeEpoch }
    var statusForSettings: String {
        taskReminderLocalized(statusMessageKey ?? "Local alerts for scheduled tasks and deadlines.")
    }

    func setEnabled(_ enabled: Bool) async {
        enableIntentEpoch &+= 1
        let intent = enableIntentEpoch
        scopeEpoch &+= 1
        let token = invalidateImmediately()
        guard enabled else {
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            statusMessageKey = nil
            onSettingsChanged?()
            await adapter.invalidate(to: token)
            return
        }
        let status = await adapter.authorizationStatus()
        guard intent == enableIntentEpoch else { return }
        let allowed: Bool
        if status == .notDetermined {
            do { allowed = try await adapter.requestAuthorization() }
            catch {
                guard intent == enableIntentEpoch else { return }
                logger.error("Could not request notification permission: \(error.localizedDescription)")
                statusMessageKey = "Notification permission is unavailable."
                defaults.set(false, forKey: Self.enabledDefaultsKey)
                onSettingsChanged?()
                await adapter.invalidate(to: invalidateImmediately())
                return
            }
        } else {
            allowed = status == .authorized || status == .provisional || status == .ephemeral
        }
        guard intent == enableIntentEpoch else { return }
        defaults.set(allowed, forKey: Self.enabledDefaultsKey)
        statusMessageKey = allowed ? nil : "Allow notifications in iOS Settings to enable task reminders."
        onSettingsChanged?()
        if !allowed {
            await adapter.invalidate(to: invalidateImmediately())
        } else {
            onCoreMutation?()
        }
    }

    func refreshPermissionStatus() async {
        let token = epoch
        let status = await adapter.authorizationStatus()
        guard token == epoch else { return }
        if status == .denied {
            enableIntentEpoch &+= 1
            statusMessageKey = "Allow notifications in iOS Settings to enable task reminders."
            if isEnabled {
                defaults.set(false, forKey: Self.enabledDefaultsKey)
                scopeEpoch &+= 1
                let token = invalidateImmediately()
                await adapter.invalidate(to: token)
            }
        } else if statusMessageKey == "Allow notifications in iOS Settings to enable task reminders." {
            statusMessageKey = nil
        }
        onSettingsChanged?()
    }

    func disableBeforeGraphMutation() async {
        enableIntentEpoch &+= 1
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        statusMessageKey = nil
        onSettingsChanged?()
        scopeEpoch &+= 1
        let token = invalidateImmediately()
        await adapter.invalidate(to: token)
    }

    func invalidateForGraphMutation() async {
        await withGraphMutation {}
    }

    func graphMutationDidFinish(succeeded: Bool) {
        if succeeded { onGraphMutationCompleted?() }
        else { onCoreMutation?() }
    }

    // Keep old-scope callbacks fenced throughout cleanup AND the graph effect.
    // Invalidating only before an awaited cleanup lets the old graph publish a
    // newer plan before the actual switch has even started.
    func withGraphMutation<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async rethrows -> Result {
        graphMutationDepth += 1
        scopeEpoch &+= 1
        let token = invalidateImmediately()
        defer {
            graphMutationDepth -= 1
            invalidateImmediately()
        }
        await adapter.invalidate(to: token)
        return try await operation()
    }

    func beginRefresh() -> UInt64 {
        invalidateImmediately()
    }

    func clearAndDrain() async {
        await adapter.invalidate(to: invalidateImmediately())
    }

    func clearAndDrain(ifCurrent token: UInt64) async {
        // A superseded attempt joins its own reconciliation so outstanding
        // writes have drained before a background completion releases budget.
        await adapter.invalidateIfCurrent(to: token)
    }

    // Background callers await both the fresh core read and the serialized
    // notification write. A superseded attempt waits for its own writes but
    // must not invalidate a newer refresh.
    func refreshAndDrain(
        expectedGraphID: String,
        refreshToken: UInt64? = nil,
        fetchProjection: @MainActor () async -> String?
    ) async -> Bool {
        let token = refreshToken ?? beginRefresh()
        guard token == epoch, !Task.isCancelled else {
            await clearAndDrain(ifCurrent: token)
            return false
        }
        guard isEnabled else {
            await clearAndDrain(ifCurrent: token)
            return true
        }
        if !Task.isCancelled, let response = await fetchProjection(),
           await reconcile(response, expectedGraphID: expectedGraphID, refreshToken: token) {
            return true
        } else {
            await adapter.invalidateIfCurrent(to: token)
            return false
        }
    }

    @discardableResult
    func reconcile(_ response: String, expectedGraphID: String, refreshToken token: UInt64) async -> Bool {
        guard isEnabled, graphMutationDepth == 0, token == epoch, !Task.isCancelled else { return false }
        do {
            let projection = try JSONDecoder().decode(
                TaskReminderRPCEnvelope<NativeTaskReminderProjection>.self,
                from: Data(response.utf8)
            ).result
            guard graphMutationDepth == 0, token == epoch, !Task.isCancelled else { return false }
            guard projection.graphId == expectedGraphID, projection.ready, projection.complete else {
                await adapter.invalidateIfCurrent(to: token)
                return false
            }
            let status = await adapter.authorizationStatus()
            guard graphMutationDepth == 0, token == epoch, !Task.isCancelled else { return false }
            guard status == .authorized || status == .provisional || status == .ephemeral else {
                enableIntentEpoch &+= 1
                defaults.set(false, forKey: Self.enabledDefaultsKey)
                statusMessageKey = "Allow notifications in iOS Settings to enable task reminders."
                onSettingsChanged?()
                scopeEpoch &+= 1
                await adapter.invalidate(to: token)
                return false
            }
            let plan = TaskReminderPlan.make(from: projection, now: now())
            guard token == epoch, !Task.isCancelled else { return false }
            let scheduled = await adapter.reconcile(plan, epoch: token)
            guard token == epoch, isEnabled, !Task.isCancelled else { return false }
            statusMessageKey = scheduled ? nil : "Could not schedule task reminders."
            onSettingsChanged?()
            return scheduled
        } catch {
            logger.error("Could not read the task reminder projection: \(error.localizedDescription)")
            await adapter.invalidateIfCurrent(to: token)
            return false
        }
    }

    @discardableResult
    private func invalidateImmediately() -> UInt64 {
        epoch &+= 1
        adapter.advance(to: epoch)
        return epoch
    }
}

// One OS caller owns one sync request. Coalesced callers share the first
// operation's reminder epoch, while expiration only cleans up when the final
// caller releases that shared operation. No continuation consults global work.
@MainActor
final class TaskReminderBackgroundAttempt {
    @MainActor private final class ResponseContext {
        var active = true
    }
    @TaskLocal private static var responseContext: ResponseContext?
    private let request = GraphSyncCoordinator.BackgroundRequest()
    private var sync: GraphSyncCoordinator?
    private var refreshToken: UInt64?
    private var expirationDrain: Task<Void, Never>?
    private var expiredNetworkTask: Task<Bool, Never>?

    nonisolated init() {}

    // Store.apply invokes its observer in the awaiting caller's task. Children
    // inherit the context but stop coalescing when the awaited sync returns.
    // Scene/UI tasks have their own context and reserve epochs normally.
    static func refreshAfterCoreResponse(_ refresh: () -> Void) {
        guard responseContext?.active != true else { return }
        refresh()
    }

    func run(
        reminders: TaskReminderCoordinator,
        sync: GraphSyncCoordinator,
        synchronizeGraph: @escaping @MainActor @Sendable () async -> String?,
        fetchProjection: @escaping @MainActor @Sendable (String) async -> String?
    ) async -> Bool {
        guard expirationDrain == nil else { return false }
        self.sync = sync
        return await sync.runBackground(request: request, expirationCleanup: { [self] in
            if let refreshToken { await reminders.clearAndDrain(ifCurrent: refreshToken) }
        }) { [self] in
            let token = reminders.beginRefresh()
            refreshToken = token
            let context = ResponseContext()
            let graphID = await Self.$responseContext.withValue(context) {
                defer { context.active = false }
                return await synchronizeGraph()
            }
            guard !Task.isCancelled, reminders.currentEpoch == token, let graphID else {
                await reminders.clearAndDrain(ifCurrent: token)
                return false
            }
            return await reminders.refreshAndDrain(
                expectedGraphID: graphID, refreshToken: token
            ) { await fetchProjection(graphID) }
        }
    }

    func expireAndDrain() async {
        if let expirationDrain { await expirationDrain.value; return }
        let drain = Task { [self] in
            expiredNetworkTask = await sync?.expireBackground(request: request)
        }
        expirationDrain = drain
        await drain.value
    }

    func awaitExpiredNetworkTask() async {
        _ = await expiredNetworkTask?.value
    }
}

struct TaskReminderRPCEnvelope<Result: Decodable>: Decodable {
    let result: Result
}

// OS expiration callbacks can run off MainActor. Claim expiration before
// cancellation can resume normal completion, then drain alerts before releasing
// the OS budget. Network teardown is deliberately after that release.
@MainActor
final class TaskReminderBackgroundCompletion {
    private enum State: Sendable { case running, expiring, finished }
    private let state = OSAllocatedUnfairLock(initialState: State.running)
    private let clearAndDrain: @MainActor @Sendable () async -> Void
    private let completion: @MainActor @Sendable (Bool) -> Void
    private let afterExpiration: @MainActor @Sendable () async -> Void

    nonisolated init(
        clearAndDrain: @escaping @MainActor @Sendable () async -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void,
        afterExpiration: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.clearAndDrain = clearAndDrain
        self.completion = completion
        self.afterExpiration = afterExpiration
    }

    func finish(success: Bool) {
        let shouldFinish = state.withLock { value in
            guard case .running = value else { return false }
            value = .finished
            return true
        }
        if shouldFinish { completion(success) }
    }

    nonisolated func expire(cancel: @Sendable () -> Void) {
        let didClaim = state.withLock { value in
            guard case .running = value else { return false }
            value = .expiring
            return true
        }
        guard didClaim else { return }
        cancel()
        Task { @MainActor in
            await clearAndDrain()
            state.withLock { $0 = .finished }
            completion(false)
            await afterExpiration()
        }
    }
}
