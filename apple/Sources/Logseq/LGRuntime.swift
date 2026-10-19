import Foundation
import LUIAppleBackend
import Observation
import LogseqModel
import os

private struct LGPatchMetadata: Decodable {
    let generation: Int
}

public struct LGPlatformCommandBatch: Equatable, Sendable {
    public let revision: Int
    public let graphName: String?
    public let commands: [LogseqOutlinerCommand]

    public init(
        revision: Int,
        graphName: String?,
        commands: [LogseqOutlinerCommand]
    ) {
        self.revision = revision
        self.graphName = graphName
        self.commands = commands
    }
}

private struct LGPendingHostUpdate {
    let kind: String
    let payload: String
}


private struct LGCoreResponseEnvelope: Decodable {
    let result: Result?

    struct Result: Decodable {
        let isPendingSyncPatch: Bool?
        let isOutlinerPatch: Bool?
        let graphName: String?
        let outlinerCommandRevision: Int?
        let outlinerCommands: [LogseqOutlinerCommand]?
        let outlinerState: OutlinerState?
        let nodeRoutes: [NodeRoute]?
        let hasPendingSemanticOperations: Bool?
        let pendingSyncRequest: PendingSyncRequest?
    }

    struct NodeRoute: Decodable {
        let outlinerState: OutlinerState?
    }

    struct OutlinerState: Decodable {
        let autocomplete: Autocomplete?
    }

    struct Autocomplete: Decodable {}

    struct PendingSyncRequest: Decodable {}
}

private struct LGCoreSyncProjection: Equatable {
    let hasPendingSemanticOperations: Bool
    let hasPendingSyncRequest: Bool
}


public enum LGRuntimeError: Error, Equatable {
    case emptyInitializationPatch
}


@MainActor
public final class LGRuntime {
    public let renderer: LGRenderer
    public private(set) var lastError: String?
    public private(set) var isStarted = false

    @ObservationIgnored
    private let native: any LGNativeCalling

    @ObservationIgnored
    private let effectExecutor: any LGEffectExecuting

    @ObservationIgnored
    private weak var platformCommandHandler: (any LGPlatformCommandHandling)?

    @ObservationIgnored
    private var isDrainingEffects = false

    @ObservationIgnored
    private var pendingCoreResponses: [String] = []

    @ObservationIgnored
    private var pendingHostUpdates: [LGPendingHostUpdate] = []

    @ObservationIgnored
    private var lastPlatformCommandRevision = 0

    @ObservationIgnored
    private var lastAuthoritativeCoreResponse: String?

    @ObservationIgnored
    private var lastCoreSyncProjection: LGCoreSyncProjection?

    @ObservationIgnored
    private var authoritativeCoreResponseInvalidated = false

    @ObservationIgnored
    private var outlinerAutosaveTask: Task<Void, Never>?

    @ObservationIgnored
    private var outlinerAutosavePending = false

    @ObservationIgnored
    private let outlinerAutosaveDelayNanoseconds: UInt64

    private static let log = Logger(subsystem: "com.logseq.logseq", category: "runtime")

    @ObservationIgnored
    private var patchTail: Task<Void, Never>?

    @ObservationIgnored
    private var patchApplyEpoch = 0

    public init(
        native: any LGNativeCalling,
        effectExecutor: any LGEffectExecuting = LGCoreEffectExecutor(),
        platformCommandHandler: (any LGPlatformCommandHandling)? = nil,
        outlinerAutosaveDelayNanoseconds: UInt64 =
            LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
                eventType: "textChanged"
            )
    ) {
        self.native = native
        self.effectExecutor = effectExecutor
        self.platformCommandHandler = platformCommandHandler
        self.outlinerAutosaveDelayNanoseconds = outlinerAutosaveDelayNanoseconds
        renderer = LGRenderer()
        renderer.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    public func start(
        platformCode: Int,
        hostCode: Int = 2,
        authenticationCode: Int = 0
    ) throws {
        guard !isStarted else { return }
        lastAuthoritativeCoreResponse = nil
        lastCoreSyncProjection = nil
        authoritativeCoreResponseInvalidated = false
        let initialPatch = native.initialize(
            platformCode: platformCode,
            hostCode: hostCode,
            authenticationCode: authenticationCode
        )
        guard !initialPatch.isEmpty else {
            throw LGRuntimeError.emptyInitializationPatch
        }
        // Before the first view exists, commit the complete local state now.
        // Live updates keep collection-view coalescing enabled.
        let coalescesCommits = renderer.backend.coalescesCommits
        renderer.backend.coalescesCommits = false
        defer { renderer.backend.coalescesCommits = coalescesCommits }
        invalidatePendingPatchApplies()
        try apply(initialPatch)
        isStarted = true
        while !pendingCoreResponses.isEmpty {
            let response = pendingCoreResponses.removeFirst()
            try applyCoreResponse(response, synchronously: true)
        }
        while !pendingHostUpdates.isEmpty {
            let update = pendingHostUpdates.removeFirst()
            try apply(native.applyHostUpdate(kind: update.kind, payload: update.payload))
        }
        scheduleEffectDrain()
    }

    public func stop() {
        guard isStarted else { return }
        cancelOutlinerAutosave()
        invalidatePendingPatchApplies()
        do {
            try apply(native.dispose())
        } catch {
            lastError = String(describing: error)
            #if DEBUG
            print("Logseq renderer event failed: \(lastError ?? "unknown error")")
            #endif
        }
        isStarted = false
    }

    public func applyCoreResponse(_ response: String) throws {
        try applyCoreResponse(response, synchronously: false)
    }

    private func applyCoreResponse(_ response: String, synchronously: Bool) throws {
        guard isStarted else {
            pendingCoreResponses.append(response)
            return
        }
        let envelope = decodeCoreResponse(response)
        guard shouldApplyCoreResponse(response, envelope: envelope) else {
            Self.log.notice("skipped core response (deduped) pendingSync=\(envelope?.result?.isPendingSyncPatch ?? false, privacy: .public) outliner=\(envelope?.result?.isOutlinerPatch ?? false, privacy: .public)")
            deliverPlatformCommands(envelope)
            return
        }
        let patch = native.applySnapshot(response)
        if synchronously {
            try apply(patch)
        } else {
            enqueueApply(patch)
        }
        recordAppliedCoreResponse(response, envelope: envelope)
        deliverPlatformCommands(envelope)
    }

    private func shouldApplyCoreResponse(
        _ response: String,
        envelope: LGCoreResponseEnvelope?
    ) -> Bool {
        guard let result = envelope?.result else { return true }
        if result.isPendingSyncPatch == true {
            return syncProjection(result) != lastCoreSyncProjection
        }
        if result.isOutlinerPatch == true {
            return true
        }
        return response != lastAuthoritativeCoreResponse
            || authoritativeCoreResponseInvalidated
    }

    private func recordAppliedCoreResponse(
        _ response: String,
        envelope: LGCoreResponseEnvelope?
    ) {
        guard let result = envelope?.result else {
            authoritativeCoreResponseInvalidated = true
            return
        }
        if result.isPendingSyncPatch == true {
            lastCoreSyncProjection = syncProjection(result)
            authoritativeCoreResponseInvalidated = true
        } else if result.isOutlinerPatch == true {
            authoritativeCoreResponseInvalidated = true
        } else {
            lastAuthoritativeCoreResponse = response
            lastCoreSyncProjection = syncProjection(result)
            authoritativeCoreResponseInvalidated = false
        }
    }

    private func decodeCoreResponse(_ response: String) -> LGCoreResponseEnvelope? {
        try? JSONDecoder().decode(
            LGCoreResponseEnvelope.self,
            from: Data(response.utf8)
        )
    }

    private func syncProjection(
        _ result: LGCoreResponseEnvelope.Result
    ) -> LGCoreSyncProjection {
        LGCoreSyncProjection(
            hasPendingSemanticOperations: result.hasPendingSemanticOperations == true,
            hasPendingSyncRequest: result.pendingSyncRequest != nil
        )
    }

    public func applyHostUpdate(kind: String, payload: String) throws {
        guard isStarted else {
            pendingHostUpdates.append(LGPendingHostUpdate(kind: kind, payload: payload))
            return
        }
        enqueueApply(native.applyHostUpdate(kind: kind, payload: payload))
    }

    private func receive(_ event: LGRendererEvent) {
        let patch: String
        switch event.kind {
        case .appear:
            patch = native.appear(node: event.nodeID)
        case .press:
            patch = native.press(node: event.nodeID)
        case .longPress:
            patch = native.longPress(node: event.nodeID)
        case .textChanged:
            patch = native.textChanged(node: event.nodeID, text: event.text ?? "")
        case .submit:
            patch = native.submit(node: event.nodeID)
        case .toggleChanged:
            patch = native.toggleChanged(
                node: event.nodeID,
                checked: event.checked ?? false
            )
        case .change:
            patch = native.change(node: event.nodeID)
        case .valueChanged:
            patch = native.valueChanged(node: event.nodeID, value: event.value ?? 0.0)
        case .dismiss:
            patch = native.dismiss(node: event.nodeID)
        case .doublePress:
            patch = native.doublePress(node: event.nodeID)
        case .scrollCompleted:
            patch = native.scrollCompleted(
                node: event.nodeID,
                token: event.token ?? 0,
                outcome: event.outcome ?? ""
            )
        case .visibleRange:
            patch = native.visibleRange(
                node: event.nodeID,
                first: event.first ?? 0,
                last: event.last ?? 0
            )
        case .picked:
            patch = native.picked(node: event.nodeID, payload: event.payload ?? "")
        case .extension:
            guard let identifier = event.extensionIdentifier,
                  let name = event.extensionName,
                  let values = event.extensionValues else {
                lastError = "Invalid LG extension event"
                return
            }
            let text = Self.extensionString(values, name: "title")
                ?? Self.extensionString(values, name: "query")
                ?? Self.extensionString(values, name: "uuid")
                ?? ""
            let value = Self.extensionInt(values, name: "caret-utf16-offset")
                ?? Self.extensionInt(values, name: "selection-length")
                ?? Self.extensionInt(values, name: "count")
                ?? Self.extensionPlacement(values)
                ?? 0
            patch = native.extensionEvent(
                node: event.nodeID,
                identifier: identifier,
                name: name,
                text: text,
                value: value
            )
        }

        enqueueApply(patch)
        scheduleEffectDrain()
    }

    private static func extensionString(
        _ values: [String: LUIExtensionValue],
        name: String
    ) -> String? {
        guard let rawValue = values[name],
              case let .string(value) = rawValue else { return nil }
        return value
    }

    private static func extensionPlacement(_ values: [String: LUIExtensionValue]) -> Int? {
        guard let placement = extensionString(values, name: "placement") else { return nil }
        switch placement {
        case "before": return 0
        case "inside": return 1
        case "after": return 2
        default: return nil
        }
    }

    private static func extensionInt(
        _ values: [String: LUIExtensionValue],
        name: String
    ) -> Int? {
        guard let rawValue = values[name],
              case let .int(value) = rawValue else { return nil }
        return value
    }

    private func scheduleEffectDrain() {
        guard !isDrainingEffects else { return }
        isDrainingEffects = true
        Task { [weak self] in
            await self?.drainEffects()
        }
    }

    private func drainEffects() async {
        defer { isDrainingEffects = false }
        while true {
            let encoded = native.takeEffect()
            if encoded.isEmpty {
                if outlinerAutosavePending {
                    outlinerAutosavePending = false
                    await executeOutlinerAutosave()
                    continue
                }
                return
            }

            let effect: LGEffect
            do {
                let data = Data(encoded.utf8)
                if let dispatch = try? JSONDecoder().decode(
                    LGEffectDispatch.self,
                    from: data
                ) {
                    #if DEBUG
                    print(
                        "LOGSEQ_LG_EFFECT dispatch patch_generation="
                            + String(Self.patchGeneration(dispatch.patch) ?? -1)
                            + " kind=\(dispatch.effect.kind)"
                    )
                    #endif
                    enqueueApply(dispatch.patch)
                    effect = dispatch.effect
                } else {
                    #if DEBUG
                    print("LOGSEQ_LG_EFFECT legacy-without-patch payload=\(encoded)")
                    #endif
                    effect = try JSONDecoder().decode(LGEffect.self, from: data)
                }
            } catch {
                lastError = "Invalid LG effect: \(String(describing: error))"
                return
            }

            cancelOutlinerAutosaveBeforeExecuting(effect)
            Self.log.notice("effect start id=\(effect.id, privacy: .public) kind=\(effect.kind, privacy: .public)")
            let resolution = await effectExecutor.execute(effect)
            Self.log.notice("effect resolved id=\(effect.id, privacy: .public) kind=\(effect.kind, privacy: .public) succeeded=\(resolution.succeeded, privacy: .public)")
            if !resolution.succeeded {
                Self.log.error("effect failed id=\(effect.id, privacy: .public) kind=\(effect.kind, privacy: .public) message=\(resolution.message, privacy: .public)")
            }
            if resolution.succeeded,
               case .coreResponse = resolution.output {
                enqueueApply(native.applySnapshot(resolution.message))
            }
            enqueueApply(native.resolveEffect(
                id: effect.id,
                succeeded: resolution.succeeded,
                message: resolution.message
            ))
            if resolution.succeeded {
                switch resolution.output {
                case .coreResponse:
                    let envelope = decodeCoreResponse(resolution.message)
                    deliverPlatformCommands(envelope)
                    scheduleOutlinerAutosaveIfNeeded(
                        after: effect,
                        envelope: envelope
                    )
                    let syncResolution = await startSyncIfNeeded(
                        envelope: envelope
                    )
                    Self.log.notice("startSync resolved id=\(effect.id, privacy: .public) succeeded=\(syncResolution.succeeded, privacy: .public)")
                    if !syncResolution.succeeded {
                        lastError = syncResolution.message
                        return
                    }
                case let .hostUpdate(kind):
                    enqueueApply(native.applyHostUpdate(
                        kind: kind,
                        payload: resolution.message
                    ))
                case .discard:
                    break
                }
            }
            if resolution.succeeded && (effect.kind == "send-asset" || effect.kind == "send-capture" || effect.kind == "send-task") {
                // A send may finish while backgrounded; do not restore already submitted drafts.
                enqueueApply(native.applyHostUpdate(kind: "save-ui-session", payload: "null"))
            }
            lastError = resolution.succeeded ? nil : resolution.message
        }
    }

    func drainEffectsForTesting() async {
        await drainEffects()
        await patchTail?.value
    }

    private func deliverPlatformCommands(_ envelope: LGCoreResponseEnvelope?) {
        guard let result = envelope?.result,
              let revision = result.outlinerCommandRevision,
              revision > lastPlatformCommandRevision else { return }
        lastPlatformCommandRevision = revision
        guard let commands = result.outlinerCommands, !commands.isEmpty else { return }
        platformCommandHandler?.handle(LGPlatformCommandBatch(
            revision: revision,
            graphName: result.graphName,
            commands: commands
        ))
    }

    private func cancelOutlinerAutosaveBeforeExecuting(_ effect: LGEffect) {
        guard effect.kind.contains("outliner"),
              effect.kind != "move-outliner-caret" else { return }
        cancelOutlinerAutosave()
    }

    private func cancelOutlinerAutosave() {
        outlinerAutosaveTask?.cancel()
        outlinerAutosaveTask = nil
        outlinerAutosavePending = false
    }

    private func scheduleOutlinerAutosaveIfNeeded(
        after effect: LGEffect,
        envelope: LGCoreResponseEnvelope?
    ) {
        let shouldSchedule: Bool
        switch effect.kind {
        case "change-outliner-text":
            shouldSchedule = !responseHasOutlinerAutocomplete(envelope)
        default:
            shouldSchedule = false
        }
        guard shouldSchedule else { return }
        outlinerAutosaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: outlinerAutosaveDelayNanoseconds)
            guard !Task.isCancelled else { return }
            outlinerAutosaveTask = nil
            outlinerAutosavePending = true
            scheduleEffectDrain()
        }
    }

    private func responseHasOutlinerAutocomplete(_ envelope: LGCoreResponseEnvelope?) -> Bool {
        let activeState = envelope?.result?.nodeRoutes?.last?.outlinerState
            ?? envelope?.result?.outlinerState
        return activeState?.autocomplete != nil
    }

    private func startSyncIfNeeded(
        envelope: LGCoreResponseEnvelope?
    ) async -> LGEffectResolution {
        guard let result = envelope?.result,
           result.hasPendingSemanticOperations == true || result.pendingSyncRequest != nil else {
            return LGEffectResolution(
                succeeded: true,
                message: "",
                output: .discard
            )
        }
        return await effectExecutor.execute(
            LGEffect(id: 0, kind: "sync-now", text: "")
        )
    }

    private func executeOutlinerAutosave() async {
        let effect = LGEffect(id: 0, kind: "save-outliner-editing", text: "")
        let resolution = await effectExecutor.execute(effect)
        guard resolution.succeeded else {
            lastError = resolution.message
            return
        }
        enqueueApply(native.applySnapshot(resolution.message))
        let syncEnvelope = decodeCoreResponse(resolution.message)
        deliverPlatformCommands(syncEnvelope)

        let syncResolution = await startSyncIfNeeded(envelope: syncEnvelope)
        if syncResolution.succeeded {
            lastError = nil
        } else {
            lastError = syncResolution.message
        }
    }

    private func apply(_ patch: String) throws {
        guard !patch.isEmpty else { return }
        #if DEBUG
        let gen = Self.patchGeneration(patch) ?? -1
        print("LOGSEQ_LG_PATCH apply generation=\(gen)")
        if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            let dir = docs.appendingPathComponent("lui-patches", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            try? patch.write(
                to: dir.appendingPathComponent("gen-\(gen).json"),
                atomically: true, encoding: .utf8
            )
        }
        #endif
        try renderer.apply(patchJSON: patch)
        lastError = nil
    }

    /// The core produces patches in generation order and applies must stay in
    /// that order, but JSON decoding is pure work that doesn't belong in the
    /// 120Hz frame budget. Each patch decodes eagerly on a detached task and
    /// a chained tail applies batches serially on the main actor — decode of
    /// the next batch overlaps apply of the previous one without reordering.
    private func enqueueApply(_ patch: String) {
        guard !patch.isEmpty else { return }
        let epoch = patchApplyEpoch
        let decodeTask = Task.detached {
            try LUIAppleBackend.decode(patch)
        }
        let previous = patchTail
        patchTail = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                let decoded = try await decodeTask.value
                guard epoch == self.patchApplyEpoch else {
                    Self.log.warning("dropped stale patch generation=\(Self.patchGeneration(patch) ?? -1, privacy: .public) epoch=\(epoch, privacy: .public) current=\(self.patchApplyEpoch, privacy: .public)")
                    return
                }
                Self.log.notice("apply patch generation=\(Self.patchGeneration(patch) ?? -1, privacy: .public)")
                #if DEBUG
                if let docs = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first {
                    let dir = docs.appendingPathComponent("lui-patches", isDirectory: true)
                    try? FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true
                    )
                    try? patch.write(
                        to: dir.appendingPathComponent(
                            "gen-\(Self.patchGeneration(patch) ?? -1).json"
                        ),
                        atomically: true, encoding: .utf8
                    )
                }
                #endif
                try self.renderer.apply(decoded: decoded)
                self.lastError = nil
            } catch {
                guard epoch == self.patchApplyEpoch else { return }
                self.lastError = String(describing: error)
                Self.log.error("renderer apply failed: \(self.lastError ?? "unknown", privacy: .public)")
            }
        }
    }

    /// Drops in-flight patch applies — pending tasks check the epoch after
    /// decoding and discard stale batches, so a following synchronous apply
    /// (initial mount, dispose) can't be reordered behind a stale decode.
    private func invalidatePendingPatchApplies() {
        patchApplyEpoch += 1
        patchTail = nil
    }

    private static func patchGeneration(_ patch: String) -> Int? {
        try? JSONDecoder().decode(
            LGPatchMetadata.self,
            from: Data(patch.utf8)
        ).generation
    }
}
