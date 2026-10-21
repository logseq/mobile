package com.logseq.app.runtime

import android.app.Activity
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asImageBitmap
import com.logseq.app.AndroidAssetImporter
import com.logseq.app.AndroidAudioPlayer
import com.logseq.app.AndroidAudioRecorder
import com.logseq.app.AndroidAudioTranscriber
import com.logseq.app.AndroidPlatformServices
import com.logseq.app.CognitoAuthProvider
import com.logseq.app.ui.extensions.LogseqDialogs
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import kotlinx.coroutines.async
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import logseq.app.AndroidRuntimeLogLevel
import logseq.app.AndroidRuntimeLogSource
import logseq.app.AndroidRuntimeLogs
import org.json.JSONObject

// Kotlin port of the former Dart app state: owns the LUI
// backend, the JNI bridge, the effect drain, bootstrap/restore, graph
// catalog polling, app entries (deep links + share intents), and
// outliner platform commands. Compose state fields drive LogseqApp.
internal class LogseqRuntime(
    private val activity: Activity,
    parentScope: CoroutineScope,
    private val patchDispatcher: kotlinx.coroutines.CoroutineDispatcher =
        Dispatchers.Default.limitedParallelism(1),
) {
    private val runtimeJob = SupervisorJob(parentScope.coroutineContext[kotlinx.coroutines.Job])
    private val scope = CoroutineScope(parentScope.coroutineContext + runtimeJob)
    private var ownsCore = false

    val platformServices = AndroidPlatformServices(activity)
    val authentication = CognitoAuthProvider(activity.applicationContext, activity)
    val assetImporter = AndroidAssetImporter(activity, scope)
    val audioRecorder = AndroidAudioRecorder(activity)
    val audioPlayer = AndroidAudioPlayer(activity)

    companion object {
        private const val LOGO_IMAGE_ID = 1
    }

    private val platformEffects = AndroidPlatformEffects(
        authentication = CognitoAndroidAuthentication(authentication),
        platform = platformServices,
        attachmentsImporter = assetImporter::import,
        syncNow = ::requestSyncNow,
        presentJournalCalendar = ::presentJournalCalendar,
    )

    val backend = LuiBackend(
        onEvent = ::dispatch,
        extensions = com.logseq.app.ui.extensions.logseqExtensionRegistry(
            resolveAssetPath = platformServices::resolveAssetPath,
            onOpenImage = ::openImageGallery,
        ),
        icons = logseqIconResolver,
    )

    init {
        // The product logo ships as a bundled raster (same PNG the iOS
        // asset catalog carries); the shared view references it through
        // the image-id channel.
        backend.registerImage(
            LOGO_IMAGE_ID,
            BitmapFactory.decodeResource(
                activity.resources,
                com.logseq.app.R.drawable.logseq_logo,
            ).asImageBitmap(),
        )
    }
    private val patchFilter = LuiPatchFilter(backend)
    private val bridge = LogseqNativeBridge(onPatch = ::applyPatch)

    private var coreEffects: CoreEffectExecutor? = null
    private var effectDrain: NativeEffectDrain? = null
    private var graphCatalogAutoRefresh: GraphCatalogAutoRefresh? = null
    private val appEntries = AndroidAppEntryCoordinator(scope, ::handleAppEntry, ::reportError)
    private val outlinerCommands = OutlinerPlatformCommandDispatcher(::handleOutlinerCommandBatch)

    var rootNodeId by mutableStateOf<Long?>(null)
        private set
    var startupError by mutableStateOf<Throwable?>(null)
        private set

    @Volatile private var hasAuthenticatedSession = false
    @Volatile private var hasOpenGraph = false
    @Volatile private var appIsForeground = true
    @Volatile private var pendingSyncRequested = false
    @Volatile private var appliedServerT = -1L
    @Volatile private var selectedGraphId = ""
    @Volatile private var storageBaseUrl = ""
    private var pendingSyncJob: kotlinx.coroutines.Job? = null
    private var graphEventsJob: kotlinx.coroutines.Job? = null
    private var graphEventsGraphId: String? = null
    private var graphLifecycle: AndroidGraphLifecycle? = null
    private var activeBootstrap: kotlinx.coroutines.Job? = null
    private var activeBootstrapHadSession = false
    private var appearance by mutableStateOf("system")

    val supportsAudioTranscription: Boolean get() = AndroidAudioTranscriber.isSupported()

    init {
        bridge.onCoreIdle = { scope.launch { effectDrain?.drain(scope) } }
        logRuntime("info", "ui", "Kotlin host initialized")
    }

    fun start() {
        scope.launch {
            try {
                NativeCoreSession.gate.lock(this@LogseqRuntime)
                ownsCore = true
                val authenticationCode = platformEffects.initialAuthenticationCode()
                val storage = platformEffects.loadStorageState()
                appearance = storage.settings.appearance
                storageBaseUrl = storage.baseUrl

                val lifecycle = AndroidGraphLifecycle(
                    callCore = bridge::callCore,
                    effects = platformEffects,
                    accessTokenProvider = platformEffects::restoreAccessToken,
                    trace = ::traceGraphLifecycle,
                )
                graphLifecycle = lifecycle
                val executor = CoreEffectExecutor(
                    callCore = bridge::callCore,
                    executePlatformEffect = NativeEffectExecutor(platformEffects::execute),
                    executeGraphEffect = NativeEffectExecutor(lifecycle::execute),
                )
                coreEffects = executor
                graphCatalogAutoRefresh = GraphCatalogAutoRefresh(
                    scope = scope,
                    callCore = bridge::callCore,
                    applyCoreResponse = ::applyCoreResponse,
                    trace = { traceGraphCatalogRefresh("automatic $it") },
                )
                val drain = NativeEffectDrain(
                    runtime = object : NativeEffectRuntime {
                        override fun takeEffect() = bridge.takeEffect()
                        override fun resolveEffect(id: Long, succeeded: Boolean, message: String) =
                            bridge.resolveEffect(id, succeeded, message)
                        override fun applySnapshot(response: String) = bridge.applySnapshot(response)
                        override fun applyHostUpdate(kind: String, payload: String) =
                            bridge.applyHostUpdate(kind, payload)
                    },
                    execute = NativeEffectExecutor(::executeEffect),
                    applyPatch = ::applyPatch,
                    onError = ::reportError,
                    trace = ::traceNativeEffect,
                    afterCoreResponseApplied = { response ->
                        outlinerCommands.deliver(response)
                        trackSyncState(response)
                        ensureGraphEventsSync()
                    },
                )
                effectDrain = drain

                val rootNode = bridge.initialize(authenticationCode = authenticationCode)
                for (update in storage.startupHostUpdates) {
                    applyPatch(bridge.applyHostUpdate(update.kind, update.payload))
                }
                rootNodeId = rootNode
                NativeCoreSession.syncActive = ::syncInBackground
                scope.launch { drain.drain(scope) }
                restoreCore(hasStoredSession = authenticationCode == 3, storage = storage)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                startupError = error
                reportError(error)
            }
        }
    }

    private suspend fun syncInBackground(): BackgroundSyncResult = scope.async {
        activeBootstrap?.join()
        if (!hasAuthenticatedSession || !hasOpenGraph) BackgroundSyncResult.Skipped
        else {
            requestSyncNow()
            pendingSyncJob?.join()
            val snapshot = JSONObject(bridge.callCore("""{"apiVersion":1,"method":"snapshot","params":{}}"""))
            if (snapshot.optBoolean("ok") && snapshot.optJSONObject("result")?.isNull("pendingSyncError") == true)
                BackgroundSyncResult.Success else BackgroundSyncResult.Retry
        }
    }.await()

    fun onLifecycleResumed(resumed: Boolean) {
        appIsForeground = resumed
        updateCatalogPolling("lifecycle")
    }

    fun publishAppEntry(entry: Map<String, Any?>) = appEntries.publish(entry)

    // --- LUI event dispatch ---

    private fun dispatch(event: LuiEvent) {
        dispatchLuiEvent(event, bridge)
        val drain = effectDrain ?: return
        scope.launch { drain.drain(scope) }
    }

    private fun applyPatch(patch: String) {
        if (patch.isEmpty()) return
        try {
            val t0 = SystemClock.elapsedRealtimeNanos()
            patchFilter.applyJson(patch)
            val ms = (SystemClock.elapsedRealtimeNanos() - t0) / 1_000_000.0
            if (ms > 20) Log.d("GraphLifecycle", "applyJson took ${"%.1f".format(ms)}ms for ${patch.length} chars")
        } catch (error: Throwable) {
            reportError(error)
            startupError = error
        }
    }

    private suspend fun applyCoreResponse(response: String) {
        // Patch decode + retained-tree mutation are expensive on big graphs
        // (~0.5s for a 461KB journal patch); keep them off the main thread on a
        // single-threaded dispatcher so patch ordering stays serial.
        withContext(patchDispatcher) { applyPatch(bridge.applySnapshot(response)) }
        outlinerCommands.deliver(response)
        trackSyncState(response)
        ensureGraphEventsSync()
        effectDrain?.let { drain -> scope.launch { drain.drain(scope) } }
    }

    // The core reports the sync cursor and selected graph on every
    // snapshot; cache them so the WebSocket loop can pull entity changes
    // without holding client-side state of its own (iOS snapshot fields).
    private fun trackSyncState(response: String) {
        runCatching {
            val result = JSONObject(response).optJSONObject("result") ?: return
            if (result.has("appliedServerT") && !result.isNull("appliedServerT")) {
                appliedServerT = result.getLong("appliedServerT")
            }
            if (result.has("selectedGraphId") && !result.isNull("selectedGraphId")) {
                selectedGraphId = result.getString("selectedGraphId")
            }
        }
    }

    // --- Graph events WebSocket (port of iOS startSync/runGraphEventsOnce) ---

    private fun ensureGraphEventsSync() {
        Log.d(
            "GraphEvents",
            "ensure open=$hasOpenGraph graph=$selectedGraphId " +
                "base=$storageBaseUrl cursor=$appliedServerT " +
                "job=${graphEventsJob?.isActive} jobGraph=$graphEventsGraphId",
        )
        if (!hasOpenGraph || selectedGraphId.isEmpty() || storageBaseUrl.isEmpty()) return
        if (graphEventsJob?.isActive == true && graphEventsGraphId == selectedGraphId) return
        graphEventsJob?.cancel()
        graphEventsGraphId = selectedGraphId
        val graphId = selectedGraphId
        graphEventsJob = scope.launch {
            while (isActive) {
                val token = try {
                    platformEffects.restoreAccessToken()
                } catch (error: Throwable) {
                    logRuntime("warn", "core", "access token unavailable: $error")
                    null
                }
                if (token.isNullOrBlank() || !isActive) break
                val sync = AndroidGraphEventsSync(
                    callCore = bridge::callCore,
                    applyResponse = ::applyCoreResponse,
                    onChangesApplied = { requestSyncNow() },
                    isCancelled = { !isActive },
                )
                val outcome = try {
                    sync.runSession(AndroidGraphEventsSync.Connection(graphId, storageBaseUrl, token))
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    logRuntime("error", "core", "graph events stopped: $error")
                    break
                }
                when (outcome) {
                    is AndroidGraphEventsSync.SessionOutcome.SnapshotRequired -> {
                        logRuntime("info", "core", "snapshot required for $graphId")
                        val recovery = runCatching { graphLifecycle?.openGraphForResync(graphId) }.getOrNull()
                        if (recovery is NativeEffectResolution.CoreResponse) {
                            applyCoreResponse(recovery.response)
                        }
                        val wait = sync.completeSnapshot(recovery?.succeeded == true)
                        if (wait > 0) kotlinx.coroutines.delay(wait)
                    }
                    is AndroidGraphEventsSync.SessionOutcome.Retry -> {
                        logRuntime("warn", "core", "graph events retry in ${outcome.delayMilliseconds}ms: ${outcome.message}")
                        kotlinx.coroutines.delay(outcome.delayMilliseconds)
                    }
                    AndroidGraphEventsSync.SessionOutcome.Stopped,
                    AndroidGraphEventsSync.SessionOutcome.Completed -> break
                }
            }
        }
    }

    // --- Pending sync pump (port of iOS runPendingSyncPump) ---

    fun requestSyncNow(): Boolean {
        pendingSyncRequested = true
        if (pendingSyncJob?.isActive != true) {
            pendingSyncJob = scope.launch {
                try {
                    runPendingSyncPump()
                } catch (error: Throwable) {
                    reportError(error)
                }
            }
        }
        return true
    }

    private suspend fun runPendingSyncPump() {
        val job = kotlinx.coroutines.currentCoroutineContext().job
        do {
            pendingSyncRequested = false
            AndroidPendingSyncPump(
                callCore = bridge::callCore,
                applyResponse = ::applyCoreResponse,
                isCancelled = { !job.isActive },
                log = { level, message -> logRuntime(level, "core", message) },
            ).run()
        } while (pendingSyncRequested && job.isActive)
    }

    // --- Effects ---

    private fun openImageGallery(uuid: String, fallback: String) {
        scope.launch {
            var paths = listOf(fallback)
            var selectedIndex = 0
            try {
                val response = JSONObject(bridge.callCore(JSONObject().put("apiVersion", 1)
                    .put("method", "dispatch").put("params", JSONObject()
                        .put("action", "cachedImageGallery").put("payload", uuid)).toString()))
                if (response.optBoolean("ok")) {
                    val gallery = response.getJSONObject("result")
                    val values = gallery.getJSONArray("paths")
                    if (values.length() > 0) {
                        paths = List(values.length()) { values.getString(it) }
                        selectedIndex = gallery.optInt("selectedIndex")
                    }
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logRuntime("warn", "ui", "Could not load neighboring images: ${failure.message}")
            }
            LogseqDialogs.openImageGallery(paths, selectedIndex)
        }
    }

    private suspend fun executeEffect(effect: NativeEffect): NativeEffectResolution {
        if (effect.kind == "present-attachment") {
            return try {
                if (effect.text == "audio") {
                    presentAudioRecording(null)
                } else {
                    presentAttachment(effect.text, null)
                }
                NativeEffectResolution.Discard()
            } catch (error: Throwable) {
                reportError(error)
                NativeEffectResolution.Failure(error.toString())
            }
        }
        val executor = coreEffects
            ?: return NativeEffectResolution.Discard(
                succeeded = false,
                message = "The native core effect executor is unavailable",
            )
        val resolution = executor.execute(effect)
        if (effect.kind == "save-settings" && resolution.succeeded) {
            val storage = platformEffects.loadStorageState()
            appearance = storage.settings.appearance
            if (storage.baseUrl != storageBaseUrl) {
                graphCatalogAutoRefresh?.stopPeriodic()
                hasOpenGraph = false
                graphEventsJob?.cancel()
                pendingSyncJob?.cancel()
                graphEventsJob?.join()
                pendingSyncJob?.join()
                graphEventsJob = null
                graphEventsGraphId = null
                pendingSyncJob = null
                pendingSyncRequested = false
                selectedGraphId = ""
                appliedServerT = -1L
                storageBaseUrl = storage.baseUrl
                platformEffects.persistSelectedGraphId("")
                runCoreRestore(hasAuthenticatedSession, storage.copy(selectedGraphId = ""))
            }
        }
        if (effect.kind == "sign-in" && resolution.succeeded) {
            restoreCore(hasStoredSession = true)
        }
        if (effect.kind == "sign-out" && resolution.succeeded) {
            hasAuthenticatedSession = false
            hasOpenGraph = false
            graphCatalogAutoRefresh?.stopPeriodic()
        }
        if (resolution.succeeded &&
            effect.kind in setOf("open-graph", "unlock-graph", "create-graph")
        ) {
            hasOpenGraph = true
            graphCatalogAutoRefresh?.stopPeriodic()
            requestSyncNow()
            // First post-open snapshots ship an empty sidebar; fill it
            // off the launch path once the journal is up.
            scope.launch { runCatching { graphLifecycle?.loadSidebar() } }
        }
        if (resolution.succeeded &&
            effect.kind in setOf("send-capture", "send-task", "sync-now")
        ) {
            requestSyncNow()
        }
        return resolution
    }

    // --- Bootstrap / restore ---

    private fun restoreCore(hasStoredSession: Boolean, storage: AndroidStorageState? = null) {
        val active = activeBootstrap
        if (active != null) {
            if (hasStoredSession && !activeBootstrapHadSession) {
                scope.launch {
                    active.join()
                    restoreCore(hasStoredSession = true)
                }
            }
            return
        }
        activeBootstrapHadSession = hasStoredSession
        activeBootstrap = scope.launch {
            try {
                runCoreRestore(hasStoredSession, storage)
            } finally {
                activeBootstrap = null
            }
        }
    }

    private suspend fun runCoreRestore(hasStoredSession: Boolean, storage: AndroidStorageState?) {
        var accessToken = ""
        if (hasStoredSession) {
            try {
                accessToken = platformEffects.restoreAccessToken() ?: ""
                if (accessToken.isBlank()) {
                    error("The stored session did not return an access token")
                }
            } catch (error: Throwable) {
                hasAuthenticatedSession = false
                applyPatch(
                    bridge.applyHostUpdate(
                        kind = "authentication",
                        payload = JSONObject()
                            .put("state", "signedOut")
                            .put("errorMessage", error.toString())
                            .toString(),
                    )
                )
                AndroidLaunchMetrics.report("authentication_published")
                reportError(error)
            }
        }
        hasAuthenticatedSession = accessToken.isNotBlank()
        try {
            logRuntime("info", "core", "Restoring core state")
            val state = platformEffects.coreStartupState(accessToken, storage)
            val restored = CoreBootstrap(
                callCore = bridge::callCore,
                trace = { traceGraphLifecycle("bootstrap $it") },
            ).restore(state)
            applyCoreResponse(restored.catalogResponse)
            graphCatalogAutoRefresh?.rememberCatalog(restored.catalogResponse)
            applyPatch(
                bridge.applyHostUpdate(
                    kind = "local-graph-ids",
                    payload = org.json.JSONArray(restored.localGraphIds).toString(),
                )
            )
            hasOpenGraph = restored.graphResponse != null
            restored.graphResponse?.let { applyCoreResponse(it) }
            applyPatch(bridge.applyHostUpdate("graph-loading", "false"))
            // The catalog patch carries the authentication snapshot the UI
            // renders against; by now auth state is published either way.
            AndroidLaunchMetrics.report("authentication_published")
            logRuntime("info", "core", "Core state restored")
            if (hasOpenGraph) requestSyncNow()
            appEntries.markReady()
            updateCatalogPolling("restore")
        } catch (error: Throwable) {
            logRuntime("error", "core", error.toString())
            reportError(error)
            applyPatch(bridge.applyHostUpdate("graph-loading", "false"))
        }
    }

    private fun updateCatalogPolling(reason: String) {
        if (shouldPollGraphCatalog(hasAuthenticatedSession, hasOpenGraph, appIsForeground)) {
            graphCatalogAutoRefresh?.startPeriodic()
            scope.launch { graphCatalogAutoRefresh?.refresh() }
        } else {
            graphCatalogAutoRefresh?.stopPeriodic()
        }
    }

    // --- App entries (deep links + share intents) ---

    private suspend fun handleAppEntry(entry: AndroidAppEntry) {
        logRuntime("info", "ui", "Handling Android app entry ${entry.kind}")
        when (entry.kind) {
            AndroidAppEntryKind.OpenCapture ->
                applyPatch(bridge.applyHostUpdate("open-capture", "{}"))
            AndroidAppEntryKind.OpenJournal -> applyAppEntryCoreRequest(
                JSONObject()
                    .put("apiVersion", 1)
                    .put("method", "dispatch")
                    .put(
                        "params",
                        JSONObject().put("action", "clearSelectedPage"),
                    )
                    .toString()
            )
            AndroidAppEntryKind.SharedText, AndroidAppEntryKind.DeepLink -> applyAppEntryCoreRequest(entry.coreRequest())
            AndroidAppEntryKind.SharedAsset ->
                addImportedAsset(requireNotNull(entry.asset), targetBlockId = null)
        }
    }

    private suspend fun presentJournalCalendar(): NativeEffectResolution {
        val day = com.logseq.app.ui.extensions.LogseqDialogs.chooseJournalDate()
            ?: return NativeEffectResolution.Discard()
        val response = JSONObject(bridge.callCore(
            JSONObject().put("apiVersion", 1).put("method", "dispatch")
                .put("params", JSONObject().put("action", "ensureJournal")
                    .put("payload", day.toString())).toString()
        ))
        if (!response.optBoolean("ok")) {
            return NativeEffectResolution.Failure(
                response.optJSONObject("error")?.optString("message") ?: "Could not open journal"
            )
        }
        val uuid = response.getJSONObject("result").getString("uuid")
        return NativeEffectResolution.HostUpdate(kind = "open-node", payload = JSONObject.quote(uuid))
    }

    private suspend fun applyAppEntryCoreRequest(request: String) {
        val response = bridge.callCore(request)
        val decoded = JSONObject(response)
        if (!decoded.optBoolean("ok")) {
            error("The native core rejected the Android app entry")
        }
        applyCoreResponse(response)
        decoded.optJSONObject("result")?.optString("deepLinkQuickAction")?.takeIf(String::isNotEmpty)?.let { action ->
            applyPatch(bridge.applyHostUpdate("open-quick-action", JSONObject.quote(action)))
        }
    }

    // --- Attachments / audio ---

    suspend fun presentAttachment(kind: String, targetBlockId: String?) {
        logRuntime("info", "ui", "Requesting $kind attachment")
        val assets = assetImporter.import(kind)
        logRuntime("info", "ui", "Imported ${assets.size} $kind attachment(s)")
        for (asset in assets) {
            addImportedAsset(AndroidImportedAsset.fromMap(asset), targetBlockId)
        }
    }

    private suspend fun addImportedAsset(asset: AndroidImportedAsset, targetBlockId: String?) {
        val response = bridge.callCore(asset.coreRequest(targetBlockId))
        if (!JSONObject(response).optBoolean("ok")) {
            error("The native core rejected ${asset.title}")
        }
        logRuntime("info", "core", "Added attachment ${asset.title}")
        applyCoreResponse(response)
    }

    suspend fun presentAudioRecording(targetBlockId: String?) {
        // The recording sheet UI is presented by the app composable layer
        // (ui/extensions/LogseqDialogs + LogseqApp's dialog host).
        val (asset, transcriptionEnabled) =
            com.logseq.app.ui.extensions.LogseqDialogs.recordAudio(
                audioRecorder,
                supportsAudioTranscription,
            ) ?: return
        val response = bridge.callCore(asset.coreRequest(targetBlockId))
        if (!JSONObject(response).optBoolean("ok")) {
            error("The native core rejected the recorded audio asset")
        }
        applyCoreResponse(response)
        if (transcriptionEnabled) {
            scope.launch { transcribeRecording(asset) }
        }
    }

    private suspend fun transcribeRecording(asset: RecordedAudioAsset) {
        try {
            logRuntime("info", "ui", "Audio transcription started")
            val transcript = AndroidAudioTranscriber.transcribe(asset.localPath).trim()
            if (transcript.isEmpty()) return
            val response = bridge.callCore(
                asset.transcriptCoreRequest(transcript)
            )
            applyCoreResponse(response)
            logRuntime("info", "ui", "Audio transcription completed")
        } catch (error: Throwable) {
            reportError(error)
        }
    }

    // --- Outliner platform commands ---

    private suspend fun handleOutlinerCommandBatch(batch: OutlinerPlatformCommandBatch) {
        for (command in batch.commands) {
            when (command.type) {
                "haptic" -> performHaptic(command.style)
                "confirmDelete" -> confirmDeletion(command.uuids)
                "setClipboardText" -> platformServices.copyText(command.text.orEmpty())
                "setClipboardReferences" -> platformServices.copyText(
                    command.uuids.joinToString("\n") { "[[$it]]" }
                )
                "setClipboardURLs" -> platformServices.copyText(
                    command.uuids.joinToString("\n") {
                        "logseq://graph/${batch.graphName}?block-id=$it"
                    }
                )
                "pickAttachment" -> presentAttachment("files", command.uuid)
                "takePhoto" -> presentAttachment("camera", command.uuid)
                "recordAudio" -> presentAudioRecording(command.uuid)
                "focusBlock" -> Unit // autofocus handles it in the retained editor
            }
        }
    }

    private fun performHaptic(style: String?) {
        val view = activity.window.decorView
        val constant = when (style) {
            "selection" -> android.view.HapticFeedbackConstants.CLOCK_TICK
            else -> android.view.HapticFeedbackConstants.LONG_PRESS
        }
        view.performHapticFeedback(constant)
    }

    private suspend fun confirmDeletion(blockIds: List<String>) {
        if (blockIds.isEmpty()) return
        val confirmed = com.logseq.app.ui.extensions.LogseqDialogs
            .confirmDeletion(blockIds.size > 1)
        if (confirmed) {
            applyPatch(bridge.applyHostUpdate("confirm-outliner-delete", "null"))
            effectDrain?.let { drain -> scope.launch { drain.drain(scope) } }
        }
    }

    // --- Tracing / logging ---

    private fun reportError(error: Throwable) {
        logRuntime("error", "ui", error.toString())
        Log.e("LogseqRuntime", "Effect failed", error)
        com.logseq.app.ui.extensions.LogseqDialogs.notifyError(
            "Something went wrong: $error"
        )
    }

    private fun traceNativeEffect(message: String) {
        val interesting = listOf(
            "kind=open-graph", "kind=create-graph", "kind=unlock-graph",
            "kind=refresh-graphs", "kind=send-capture", "kind=send-task",
            "kind=search-nodes", "patch",
        )
        if (interesting.none(message::contains)) return
        Log.d("NativeEffect", message)
        logRuntime("info", "ui", message)
    }

    private fun traceGraphLifecycle(message: String) {
        Log.d("GraphLifecycle", message)
        logRuntime("info", "core", message)
    }

    private fun traceGraphCatalogRefresh(message: String) {
        Log.d("GraphCatalog", message)
        logRuntime("info", "core", message)
    }

    private fun logRuntime(level: String, source: String, message: String) {
        platformServices.appendRuntimeLog(level, source, message)
    }

    fun dispose() {
        graphCatalogAutoRefresh?.dispose()
        effectDrain?.dispose()
        bridge.onCoreIdle = null
        if (ownsCore) NativeCoreSession.syncActive = null
        runtimeJob.cancel()
        NativeCoreSession.cleanupScope.launch {
            runtimeJob.join()
            if (ownsCore) {
                try { bridge.close() }
                finally {
                    ownsCore = false
                    NativeCoreSession.gate.unlock(this@LogseqRuntime)
                }
            }
        }
    }

    val effectiveAppearance: String get() = appearance
}

// Recorded audio asset produced by the recording sheet — payload shape
// matches the former android_audio_recording.dart.
internal data class RecordedAudioAsset(
    val uuid: String,
    val title: String,
    val assetType: String,
    val size: Long,
    val checksum: String,
    val localPath: String,
) {
    fun coreRequest(targetBlockId: String?): String = JSONObject()
        .put("apiVersion", 1)
        .put("method", "dispatch")
        .put(
            "params",
            JSONObject()
                .put("action", "addAsset")
                .put(
                    "payload",
                    JSONObject()
                        .put("uuid", uuid)
                        .put("title", title)
                        .put("assetType", assetType)
                        .put("assetSize", size)
                        .put("assetChecksum", checksum)
                        .put("localPath", localPath)
                        .apply {
                            if (!targetBlockId.isNullOrEmpty()) {
                                put("targetBlockId", targetBlockId)
                            }
                        }
                        .toString(),
                ),
        )
        .toString()

    fun transcriptCoreRequest(transcript: String): String = JSONObject()
        .put("apiVersion", 1).put("method", "dispatch")
        .put("params", JSONObject().put("action", "executeEffect").put("payload", JSONObject()
            .put("kind", "recording-transcribed").put("uuid", uuid).put("text", transcript).toString()))
        .toString()
}
