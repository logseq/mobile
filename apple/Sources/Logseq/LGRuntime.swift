import Foundation
import LUIAppleBackend
import Observation
import LogseqModel
import os

private struct LGPatchMetadata: Decodable {
    let generation: Int
}

private struct LGEffectWait: Decodable {
    let waitMs: Int
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


private struct LGCoreResponseEnvelope: Decodable, Sendable {
    let result: Result?

    struct Result: Decodable, Sendable {
        let isPendingSyncPatch: Bool?
        let isOutlinerPatch: Bool?
        let isOutlinerContentPatch: Bool?
        let isSearchPatch: Bool?
        let isReferencePatch: Bool?
        let graphName: String?
        let outlinerCommandRevision: Int?
        let outlinerCommands: [LogseqOutlinerCommand]?
        let hasPendingSemanticOperations: Bool?
        let pendingSyncRequest: PendingSyncRequest?
    }

    struct PendingSyncRequest: Decodable, Sendable {}
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

    private static let log = Logger(subsystem: "com.logseq.logseq", category: "runtime")

    @ObservationIgnored
    private var patchTail: Task<Void, Never>?

    @ObservationIgnored
    private var nativeTail: Task<String, Never>?

    @ObservationIgnored
    private var queryWait: Task<Void, Never>?

    @ObservationIgnored
    private var effectWakeVersion = 0

    @ObservationIgnored
    private var patchApplyEpoch = 0

    public init(
        native: any LGNativeCalling,
        effectExecutor: any LGEffectExecuting = LGCoreEffectExecutor(),
        platformCommandHandler: (any LGPlatformCommandHandling)? = nil
    ) {
        self.native = native
        self.effectExecutor = effectExecutor
        self.platformCommandHandler = platformCommandHandler
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
        let initialPatch = LogseqLaunchTiming.measure("core_ui_initialize") {
            native.initialize(
                platformCode: platformCode,
                hostCode: hostCode,
                authenticationCode: authenticationCode
            )
        }
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
        queryWait?.cancel()
        queryWait = nil
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
        if !synchronously {
            enqueueNative(.snapshot(response), coreResponse: response)
            return
        }
        let envelope = decodeCoreResponse(response)
        guard shouldApplyCoreResponse(response, envelope: envelope) else {
            Self.log.notice("skipped core response (deduped) pendingSync=\(envelope?.result?.isPendingSyncPatch ?? false, privacy: .public) outliner=\(envelope?.result?.isOutlinerPatch ?? false, privacy: .public)")
            deliverPlatformCommands(envelope)
            return
        }
        if synchronously {
            try apply(native.applySnapshot(response))
        } else {
            enqueueNative(.snapshot(response))
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
        if result.isOutlinerPatch == true || result.isOutlinerContentPatch == true || result.isSearchPatch == true || result.isReferencePatch == true {
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
        } else if result.isOutlinerPatch == true || result.isOutlinerContentPatch == true || result.isSearchPatch == true || result.isReferencePatch == true {
            authoritativeCoreResponseInvalidated = true
        } else {
            lastAuthoritativeCoreResponse = response
            lastCoreSyncProjection = syncProjection(result)
            authoritativeCoreResponseInvalidated = false
        }
    }

    private nonisolated static func decodeCoreResponseAsync(_ response: String) async -> LGCoreResponseEnvelope? {
        await Task.detached {
            try? JSONDecoder().decode(LGCoreResponseEnvelope.self, from: Data(response.utf8))
        }.value
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
        enqueueNative(.hostUpdate(kind, payload))
    }

    private func receive(_ event: LGRendererEvent) {
        let operation: LGNativeOperation
        switch event.kind {
        case .appear:
            operation = .appear(event.nodeID)
        case .press:
            operation = .press(event.nodeID)
        case .longPress:
            operation = .longPress(event.nodeID)
        case .textChanged:
            operation = .textChanged(event.nodeID, event.text ?? "")
        case .submit:
            operation = .submit(event.nodeID)
        case .toggleChanged:
            operation = .toggleChanged(event.nodeID, event.checked ?? false)
        case .change:
            operation = .change(event.nodeID)
        case .valueChanged:
            operation = .valueChanged(event.nodeID, event.value ?? 0.0)
        case .dismiss:
            operation = .dismiss(event.nodeID)
        case .doublePress:
            operation = .doublePress(event.nodeID)
        case .scrollCompleted:
            operation = .scrollCompleted(event.nodeID, event.token ?? 0, event.outcome ?? "")
        case .visibleRange:
            operation = .visibleRange(event.nodeID, event.first ?? 0, event.last ?? 0)
        case .picked:
            operation = .picked(event.nodeID, event.payload ?? "")
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
            operation = .extensionEvent(event.nodeID, identifier, name, text, value)
        }

        enqueueNative(operation)
        scheduleEffectDrain()
    }

    // Keep VM execution and patch delivery in one ordered chain. The core's
    // worker may be reading a large graph; the main actor must never wait on
    // its semaphore, including for a seemingly small input event.
    @discardableResult
    private func enqueueNative(
        _ operation: LGNativeOperation,
        effectDispatch: Bool = false,
        coreResponse: String? = nil
    ) -> Task<String, Never> {
        let previous = nativeTail
        let epoch = patchApplyEpoch
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, epoch == self.patchApplyEpoch else { return "" }
            var envelope: LGCoreResponseEnvelope?
            if let coreResponse {
                envelope = await Self.decodeCoreResponseAsync(coreResponse)
                guard epoch == self.patchApplyEpoch else { return "" }
                guard self.shouldApplyCoreResponse(coreResponse, envelope: envelope) else {
                    self.deliverPlatformCommands(envelope)
                    return ""
                }
            }
            let result = await self.native.performAsync(operation)
            guard epoch == self.patchApplyEpoch else { return "" }
            if effectDispatch {
                if let dispatch = try? JSONDecoder().decode(LGEffectDispatch.self, from: Data(result.utf8)) {
                    self.enqueueApply(dispatch.patch)
                }
            } else {
                self.enqueueApply(result)
            }
            if let coreResponse {
                self.recordAppliedCoreResponse(coreResponse, envelope: envelope)
                self.deliverPlatformCommands(envelope)
            }
            if case .takeEffect = operation { } else { self.scheduleEffectDrain() }
            return result
        }
        nativeTail = task
        return task
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
        guard isStarted else { return }
        effectWakeVersion &+= 1
        queryWait?.cancel()
        guard !isDrainingEffects else { return }
        isDrainingEffects = true
        Task { [weak self] in
            guard let self else { return }
            guard self.isStarted else {
                self.isDrainingEffects = false
                return
            }
            await self.drainEffects()
        }
    }

    private func drainEffects() async {
        defer { isDrainingEffects = false }
        let epoch = patchApplyEpoch
        while true {
            guard epoch == patchApplyEpoch else { return }
            let wakeVersion = effectWakeVersion
            let encoded = await enqueueNative(.takeEffect, effectDispatch: true).value
            guard epoch == patchApplyEpoch else { return }
            if let wait = try? JSONDecoder().decode(LGEffectWait.self, from: Data(encoded.utf8)) {
                let task = Task {
                    _ = try? await Task.sleep(for: .milliseconds(max(1, min(200, wait.waitMs))))
                }
                queryWait = task
                await task.value
                queryWait = nil
                continue
            }
            if encoded.isEmpty {
                if wakeVersion != effectWakeVersion { continue }
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

            Self.log.notice("effect start id=\(effect.id, privacy: .public) kind=\(effect.kind, privacy: .public)")
            let resolution = await effectExecutor.execute(effect)
            guard epoch == patchApplyEpoch else { return }
            Self.log.notice("effect resolved id=\(effect.id, privacy: .public) kind=\(effect.kind, privacy: .public) succeeded=\(resolution.succeeded, privacy: .public)")
            if !resolution.succeeded {
                Self.log.error("effect failed id=\(effect.id, privacy: .public) kind=\(effect.kind, privacy: .public) message=\(resolution.message, privacy: .public)")
            }
            if resolution.succeeded,
               case .coreResponse = resolution.output {
                _ = await enqueueNative(.snapshot(resolution.message)).value
            }
            _ = await enqueueNative(.resolveEffect(effect.id, resolution.succeeded, resolution.message)).value
            if resolution.succeeded {
                switch resolution.output {
                case .coreResponse:
                    let envelope = await Self.decodeCoreResponseAsync(resolution.message)
                    deliverPlatformCommands(envelope)
                case let .hostUpdate(kind):
                    _ = await enqueueNative(.hostUpdate(kind, resolution.message)).value
                case .discard:
                    break
                }
            }
            if resolution.succeeded && (effect.kind == "send-asset" || effect.kind == "send-capture" || effect.kind == "send-task") {
                // A send may finish while backgrounded; do not restore already submitted drafts.
                _ = await enqueueNative(.hostUpdate("save-ui-session", "null")).value
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

    private func apply(_ patch: String) throws {
        guard !patch.isEmpty else { return }
        let decoded = try LogseqLaunchTiming.measure("lui_patch_decode") { try LUIAppleBackend.decode(patch) }
        try LogseqLaunchTiming.measure("lui_patch_commit") { try renderer.apply(decoded: decoded) }
        #if DEBUG
        Task.detached { Self.dumpPatchIfRequested(patch, generation: decoded.generation) }
        #endif
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
            let decoded = try LUIAppleBackend.decode(patch)
            #if DEBUG
            Self.dumpPatchIfRequested(patch, generation: decoded.generation)
            #endif
            return decoded
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
                Self.log.notice("apply patch generation=\(decoded.generation, privacy: .public)")
                try self.renderer.apply(decoded: decoded)
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
        nativeTail = nil
    }

    #if DEBUG
    private nonisolated static func dumpPatchIfRequested(_ patch: String, generation: Int) {
        guard ProcessInfo.processInfo.environment["LOGSEQ_DUMP_LUI_PATCHES"] == "1",
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = docs.appendingPathComponent("lui-patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? patch.write(to: directory.appendingPathComponent("gen-\(generation).json"), atomically: true, encoding: .utf8)
    }
    #endif

    private static func patchGeneration(_ patch: String) -> Int? {
        try? JSONDecoder().decode(
            LGPatchMetadata.self,
            from: Data(patch.utf8)
        ).generation
    }
}
