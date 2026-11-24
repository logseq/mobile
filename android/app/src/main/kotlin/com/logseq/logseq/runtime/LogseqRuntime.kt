package com.logseq.logseq.runtime

import android.app.Activity
import android.graphics.BitmapFactory
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asImageBitmap
import com.logseq.logseq.AndroidAssetImporter
import com.logseq.logseq.AndroidAudioPlayer
import com.logseq.logseq.AndroidAudioRecorder
import com.logseq.logseq.AndroidAudioTranscriber
import com.logseq.logseq.AndroidWidgetContent
import com.logseq.logseq.AndroidPlatformServices
import com.logseq.logseq.CognitoAuthProvider
import com.logseq.logseq.DEFAULT_DARK_THEME
import com.logseq.logseq.isNetworkUnavailable
import com.logseq.logseq.ui.extensions.LogseqDialogs
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import dev.lui.LuiPatchBatch
import kotlinx.coroutines.async
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.logseq.logseq.AndroidRuntimeLogLevel
import com.logseq.logseq.AndroidRuntimeLogSource
import com.logseq.logseq.AndroidRuntimeLogs
import org.json.JSONObject
import com.logseq.logseq.AndroidAppEntryParser

// Kotlin port of the former Dart app state: owns the LUI
// backend, the JNI bridge, the effect drain, bootstrap/restore, graph
// catalog polling, app entries (deep links + share intents), and
// outliner platform commands. Compose state fields drive LogseqApp.
internal class LogseqRuntime(
    private val activity: Activity,
    parentScope: CoroutineScope,
) {
    private val runtimeJob = SupervisorJob(parentScope.coroutineContext[kotlinx.coroutines.Job])
    private val scope = CoroutineScope(parentScope.coroutineContext + runtimeJob)
    private var ownsCore = false
    private var widgetRefreshJob: Job? = null
    private var clipboardImageJob: Job? = null
    private var widgetRefreshPending = false

    val platformServices = AndroidPlatformServices(activity)
    val authentication = CognitoAuthProvider(activity.applicationContext)
    val assetImporter = AndroidAssetImporter(activity, scope)
    val audioRecorder = AndroidAudioRecorder(activity)
    val audioPlayer = AndroidAudioPlayer(activity)

    companion object {
        private const val LOGO_IMAGE_ID = 1
    }

    private data class InitialState(
        val storage: AndroidStorageState,
        val rootNode: Long,
        val hasStoredSession: Boolean,
        val hasInitialWidgetBlock: Boolean,
    )

    private val platformEffects = AndroidPlatformEffects(
        authentication = CognitoAndroidAuthentication(authentication),
        platform = platformServices,
        attachmentsImporter = assetImporter::import,
        syncNow = ::requestSyncNow,
        presentJournalCalendar = ::presentJournalCalendar,
    )

    val backend = LuiBackend(
        onEvent = ::dispatch,
        extensions = com.logseq.logseq.ui.extensions.logseqExtensionRegistry(
            resolveAssetPath = platformServices::resolveAssetPath,
            onOpenImage = ::openImageGallery,
            loadImage = { uuid, type -> graphAssetLoader.load(uuid, type) },
            importPastedImage = { uri ->
                val asset = checkNotNull(assetImporter.importShared(uri)) { "The image could not be imported" }
                AndroidImportedAsset.fromMap(asset).payload()
            },
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
                com.logseq.logseq.R.drawable.logseq_logo,
            ).asImageBitmap(),
        )
    }
    private val patchFilter = LuiPatchFilter(backend)
    private val bridge = LogseqNativeBridge(onPatch = ::deliverPatch)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var awaitingRendererSnapshot = false
    private var rendererSnapshotPending = false

    private val graphAssetLoader by lazy {
        AndroidGraphAssetLoader(java.io.File(activity.cacheDir, "asset-downloads"), bridge::callCore)
    }

    private var coreEffects: CoreEffectExecutor? = null
    private var effectDrain: NativeEffectDrain? = null
    private var graphCatalogAutoRefresh: GraphCatalogAutoRefresh? = null
    private val appEntries = AndroidAppEntryCoordinator(
        scope, ::handleAppEntry, ::reportQueuedAppEntryError, java.io.File(activity.filesDir, "incoming-shares"),
    )
    private val outlinerCommands = OutlinerPlatformCommandDispatcher(
        onBatch = ::handleOutlinerCommandBatch,
        onError = { error ->
            reportError(error)
            LogseqDialogs.notifyError(error.message ?: "The action could not be completed")
        },
    )

    var rootNodeId by mutableStateOf<Long?>(null)
        private set
    var isRestoringInitialGraph by mutableStateOf(false)
        private set
    var isOpeningInitialWidgetBlock by mutableStateOf(false)
        private set
    var startupError by mutableStateOf<Throwable?>(null)
        private set
    var graphProgress by mutableStateOf<AndroidGraphProgress?>(null)
        private set

    @Volatile private var hasAuthenticatedSession = false
    private var configuredAccessToken = ""
    private var restartingGraphEvents = false
    @Volatile private var hasOpenGraph = false
    @Volatile private var appIsForeground = false
    @Volatile private var pendingSyncRequested = false
    @Volatile private var appliedServerT = -1L
    @Volatile private var selectedGraphId = ""
    @Volatile private var storageBaseUrl = ""
    private val graphSyncEligibility = CoreGraphSyncEligibility()
    private var pendingSyncJob: kotlinx.coroutines.Job? = null
    @Volatile private var graphEventsSync: AndroidGraphEventsSync? = null
    private var journalDayJob: kotlinx.coroutines.Job? = null
    private var refreshedJournalDay: String? = null
    private var audioRecordingJob: kotlinx.coroutines.Job? = null
    private val graphEventsSession = AndroidForegroundSyncSession(scope)
    private var graphLifecycle: AndroidGraphLifecycle? = null
    private var activeBootstrap: kotlinx.coroutines.Job? = null
    private var activeBootstrapHadSession = false
    private var appearance by mutableStateOf("system")
    private var darkTheme by mutableStateOf(DEFAULT_DARK_THEME)

    init {
        bridge.onCoreIdle = { scope.launch { effectDrain?.drain(scope) } }
        logRuntime("info", "ui", "Kotlin host initialized")
    }

    fun start(initialWidgetLink: Map<String, Any?>?, onInitialWidgetRetained: () -> Unit) {
        isOpeningInitialWidgetBlock = initialWidgetLink != null
        scope.launch {
            try {
                NativeCoreSession.gate.lock(this@LogseqRuntime)
                ownsCore = true
                if (initialWidgetLink != null) {
                    try {
                        appEntries.publish(initialWidgetLink, initialWidgetBlock = true)
                        onInitialWidgetRetained()
                    } catch (cancelled: kotlinx.coroutines.CancellationException) {
                        throw cancelled
                    } catch (error: Exception) {
                        reportWidgetLinkError(error)
                    }
                }
                AndroidGraphImportProgress.listener = { graphId, phase, completed, total ->
                    val current = graphProgress
                    if (current?.graphId == graphId && phase in setOf("importing", "opening"))
                        graphProgress = current.copy(phase = phase, completed = completed, total = total)
                }
                // Prepare the retained tree while the activity draws its first frame.
                val (storage, rootNode, hasStoredSession, hasInitialWidgetBlock) = withContext(NativeCoreThread.dispatcher) {
                    val (authenticationCode, savedStorage, pendingWidgetBlock) = withContext(Dispatchers.IO) {
                        Triple(
                            platformEffects.initialAuthenticationCode(),
                            platformEffects.loadStorageState(),
                            appEntries.hasInitialWidgetBlocks(),
                        )
                    }
                    val root = bridge.initialize(authenticationCode = authenticationCode)
                    for (update in savedStorage.startupHostUpdates) {
                        deliverPatch(bridge.applyHostUpdate(update.kind, update.payload))
                    }
                    InitialState(savedStorage, root, authenticationCode == 3, pendingWidgetBlock)
                }
                isOpeningInitialWidgetBlock = hasInitialWidgetBlock
                isRestoringInitialGraph = hasStoredSession && storage.selectedGraphId in storage.localGraphIds
                appearance = storage.settings.appearance
                darkTheme = storage.settings.darkTheme
                storageBaseUrl = storage.baseUrl

                val lifecycle = AndroidGraphLifecycle(
                    callCore = bridge::callCore,
                    effects = platformEffects,
                    accessTokenProvider = platformEffects::restoreAccessToken,
                    trace = ::traceGraphLifecycle,
                    onProgress = { progress ->
                        val current = graphProgress
                        graphProgress = if (progress != null && current?.graphId == progress.graphId &&
                            current.phase == progress.phase && progress.total == null) current else progress
                    },
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
                        override suspend fun takeEffect() = onCore { deliverDispatchPatch(bridge.takeEffect()) }
                        // Patches decode on the core thread and reach the main thread
                        // before the drain resumes, so the returned string is empty.
                        override suspend fun resolveEffect(id: Long, succeeded: Boolean, message: String) =
                            onCore { deliverPatch(bridge.resolveEffect(id, succeeded, message)); "" }
                        override suspend fun applySnapshot(response: String) =
                            onCore { deliverPatch(bridge.applySnapshot(response)); "" }
                        override suspend fun applyHostUpdate(kind: String, payload: String) =
                            onCore { deliverPatch(bridge.applyHostUpdate(kind, payload)); "" }
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

                rootNodeId = rootNode
                NativeCoreSession.syncActive = ::syncInBackground
                NativeCoreSession.updateActiveWidgetTask = ::setWidgetTaskStatus
                NativeCoreSession.refreshActiveRandomWidget = {
                    AndroidWidgetContent.refresh(activity.applicationContext, bridge::callCore, resampleRandom = true)
                }
                scope.launch { drain.drain(scope) }
                restoreCore(hasStoredSession, storage)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                startupError = error
                isRestoringInitialGraph = false
                isOpeningInitialWidgetBlock = false
                reportError(error)
            }
        }
    }

    private suspend fun syncInBackground(): BackgroundSyncResult = scope.async {
        activeBootstrap?.join()
        if (!graphSyncEligibility.canSync(hasAuthenticatedSession, hasOpenGraph)) BackgroundSyncResult.Skipped
        else {
            requestSyncNow()
            pendingSyncJob?.join()
            if (!graphSyncEligibility.canSync(hasAuthenticatedSession, hasOpenGraph)) BackgroundSyncResult.Skipped
            else {
                val snapshot = JSONObject(bridge.callCore("""{"apiVersion":1,"method":"snapshot","params":{}}"""))
                if (snapshot.optBoolean("ok") && snapshot.optJSONObject("result")?.isNull("pendingSyncError") == true)
                    BackgroundSyncResult.Success else BackgroundSyncResult.Retry
            }
        }
    }.await()

    fun onLifecycleResumed(resumed: Boolean) {
        if (resumed && ownsCore) scheduleWidgetRefresh()
        appIsForeground = resumed
        updateCatalogPolling("lifecycle")
        ensureGraphEventsSync()
        if (resumed && hasOpenGraph) appEntries.markReady()
        journalDayJob?.cancel()
        journalDayJob = if (resumed) scope.launch {
            while (true) {
                if (hasOpenGraph) {
                    val key = selectedGraphId + ":" + java.time.ZoneId.systemDefault().id + ":" + java.time.LocalDate.now()
                    if (key != refreshedJournalDay) {
                        val response = bridge.callCore("""{"apiVersion":1,"method":"snapshot","params":{}}""")
                        if (JSONObject(response).optBoolean("ok")) {
                            applyCoreResponse(response)
                            refreshedJournalDay = key
                        }
                    }
                }
                kotlinx.coroutines.delay(30_000)
            }
        } else null
    }

    suspend fun publishAppEntry(entry: Map<String, Any?>) = appEntries.publish(entry)

    // --- LUI event dispatch ---

    private fun dispatch(event: LuiEvent) {
        // Pending editor text must reach the core before the press it precedes.
        if (event is LuiEvent.Press) NativeEditorInput.flush()
        NativeCoreThread.execute { dispatchLuiEvent(event, bridge) }
        val drain = effectDrain ?: return
        scope.launch { drain.drain(scope) }
    }

    private suspend fun <T> onCore(block: () -> T): T = withContext(NativeCoreThread.dispatcher) { block() }

    /** Apply a host update on the core thread and queue its patch for the main thread. */
    private suspend fun hostUpdate(kind: String, payload: String) =
        onCore { deliverPatch(bridge.applyHostUpdate(kind, payload)) }

    // Core thread: hand a dequeued effect's patch to deliverPatch in this same core
    // task, so later events cannot overtake it. The drain sees an empty patch.
    private fun deliverDispatchPatch(encoded: String): String {
        val envelope = runCatching { JSONObject(encoded) }.getOrNull() ?: return encoded
        val patch = envelope.optString("patch")
        if (patch.isEmpty()) return encoded
        deliverPatch(patch)
        return envelope.put("patch", "").toString()
    }

    // Core thread: decode here, then apply on the main thread in production order.
    private fun deliverPatch(patch: String) {
        if (patch.isEmpty()) return
        val batch = runCatching { traced("lui.parsePatch") { LuiPatchBatch.parse(patch) } }
        mainHandler.post { applyPatch(batch) }
    }

    private fun applyPatch(patch: String) {
        if (patch.isNotEmpty()) applyPatch(runCatching { LuiPatchBatch.parse(patch) })
    }

    private fun applyPatch(batch: Result<LuiPatchBatch>) {
        if (awaitingRendererSnapshot) {
            requestRendererSnapshot()
            return
        }
        try {
            traced("lui.applyPatch") { patchFilter.apply(batch.getOrThrow()) }
        } catch (error: Throwable) {
            awaitingRendererSnapshot = true
            Log.w("LogseqRuntime", "Rejected UI delta; requesting authoritative snapshot", error)
            requestRendererSnapshot()
        }
    }

    private fun requestRendererSnapshot() {
        if (rendererSnapshotPending) return
        rendererSnapshotPending = true
        NativeCoreThread.execute {
            try {
                bridge.resync { snapshot -> mainHandler.post { applyRendererSnapshot(snapshot) } }
            } catch (failure: Throwable) {
                mainHandler.post {
                    rendererSnapshotPending = false
                    reportError(failure)
                    startupError = failure
                }
            }
        }
    }

    private fun applyRendererSnapshot(snapshot: String) {
        rendererSnapshotPending = false
        try {
            patchFilter.applySnapshotJson(snapshot)
            awaitingRendererSnapshot = false
            startupError = null
        } catch (error: Throwable) {
            reportError(error)
            startupError = error
        }
    }

    private suspend fun applyCoreResponse(response: String) {
        // Decode big snapshot patches (~0.5s for a 461KB journal) on the core
        // thread; the retained tree is only mutated on the main thread.
        onCore { deliverPatch(bridge.applySnapshot(response)) }
        outlinerCommands.deliver(response)
        trackSyncState(response)
        ensureGraphEventsSync()
        effectDrain?.let { drain -> scope.launch { drain.drain(scope) } }
    }

    // The core reports the sync cursor and selected graph on every
    // snapshot; cache them so the WebSocket loop can pull entity changes
    // without holding client-side state of its own (iOS snapshot fields).
    private fun trackSyncState(response: String) {
        scheduleWidgetRefresh()
        graphSyncEligibility.update(response)
        if (!graphSyncEligibility.canSync(hasAuthenticatedSession, hasOpenGraph)) {
            pendingSyncRequested = false
            pendingSyncJob?.cancel()
        }
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

    private fun scheduleWidgetRefresh() {
        widgetRefreshPending = true
        if (widgetRefreshJob?.isActive == true) return
        widgetRefreshJob = scope.launch {
            while (widgetRefreshPending) {
                delay(750)
                widgetRefreshPending = false
                AndroidWidgetContent.refresh(activity.applicationContext, bridge::callCore)
            }
        }
    }

    private suspend fun setWidgetTaskStatus(change: WidgetTaskStatusChange): Boolean {
        val response = bridge.callCore(change.request())
        val saved = JSONObject(response).optBoolean("ok")
        AndroidWidgetContent.refresh(activity.applicationContext, bridge::callCore)
        if (saved) {
            applyCoreResponse(response)
            requestSyncNow()
        }
        return saved
    }

    // --- Graph events WebSocket (port of iOS startSync/runGraphEventsOnce) ---

    private suspend fun restoreCoreAccessToken(): String? {
        val token = platformEffects.restoreAccessToken()?.takeIf { it.isNotBlank() } ?: return null
        if (token == configuredAccessToken) return token
        val response = bridge.callCore(JSONObject()
            .put("apiVersion", 1).put("method", "dispatch")
            .put("params", JSONObject().put("action", "setAccessToken").put("payload", token))
            .toString())
        check(JSONObject(response).optBoolean("ok")) { "Core authentication refresh failed" }
        configuredAccessToken = token
        if (graphEventsSync != null) {
            restartingGraphEvents = true
            try {
                graphEventsSession.cancel()
                graphEventsSession.join()
            } finally {
                restartingGraphEvents = false
            }
        }
        applyCoreResponse(response)
        return token
    }

    private fun ensureGraphEventsSync() {
        Log.d(
            "GraphEvents",
            "ensure open=$hasOpenGraph graph=$selectedGraphId " +
                "base=$storageBaseUrl cursor=$appliedServerT " +
                "job=${graphEventsSession.isActive} foreground=$appIsForeground",
        )
        val sessionGraphId = selectedGraphId.takeIf {
            graphSyncEligibility.canSync(hasAuthenticatedSession, hasOpenGraph) &&
                !restartingGraphEvents && it.isNotEmpty() && storageBaseUrl.isNotEmpty()
        }
        graphEventsSession.update(sessionGraphId, appIsForeground) { graphId ->
            while (isActive) {
                val token = try {
                    restoreCoreAccessToken()
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    if (isNetworkUnavailable(error)) {
                        logRuntime("info", "core", "Authentication refresh unavailable; retrying")
                        kotlinx.coroutines.delay(5_000)
                        continue
                    }
                    logRuntime("warn", "core", "access token unavailable: ${error.javaClass.simpleName}")
                    break
                }
                if (token.isNullOrBlank() || !isActive) break
                val sync = AndroidGraphEventsSync(
                    callCore = bridge::callCore,
                    applyResponse = ::applyCoreResponse,
                    onChangesApplied = { requestSyncNow() },
                    isCancelled = { !isActive },
                )
                val outcome = try {
                    graphEventsSync = sync
                    sync.runSession(AndroidGraphEventsSync.Connection(graphId, storageBaseUrl, token))
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    logRuntime("error", "core", "graph events stopped: $error")
                    break
                } finally {
                    if (graphEventsSync === sync) graphEventsSync = null
                }
                when (outcome) {
                    is AndroidGraphEventsSync.SessionOutcome.SnapshotRequired -> {
                        logRuntime("info", "core", "snapshot required for $graphId")
                        val recovery = runCatching { graphLifecycle?.openGraphForResync(graphId) }.getOrElse {
                            if (it is kotlinx.coroutines.CancellationException) throw it
                            null
                        }
                        if (recovery is NativeEffectResolution.CoreResponse) {
                            applyCoreResponse(recovery.response)
                        }
                        if (!graphSyncEligibility.canSync(hasAuthenticatedSession, hasOpenGraph)) break
                        val failureMessage = when (recovery) {
                            is NativeEffectResolution.Failure -> recovery.message
                            is NativeEffectResolution.Discard -> recovery.message.substringAfter('\n')
                            else -> null
                        }
                        val wait = sync.completeSnapshot(recovery?.succeeded == true, failureMessage)
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
        if (!graphSyncEligibility.canSync(hasAuthenticatedSession, hasOpenGraph)) return false
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
            if (restoreCoreAccessToken().isNullOrBlank()) return
            AndroidPendingSyncPump(
                callCore = bridge::callCore,
                applyResponse = ::applyCoreResponse,
                isCancelled = { !job.isActive },
                log = { level, message -> logRuntime(level, "core", message) },
                sendWebSocket = { graphEventsSync?.sendPending(it) },
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
        val deletingOpenGraph = effect.kind == "delete-local-graph" && effect.text == selectedGraphId
        if (deletingOpenGraph) {
            hasOpenGraph = false
            graphCatalogAutoRefresh?.stopPeriodic()
            graphEventsSession.cancel()
            pendingSyncJob?.cancel()
            graphEventsSession.join()
            pendingSyncJob?.join()
            pendingSyncJob = null
            pendingSyncRequested = false
            val closed = bridge.callCore(JSONObject()
                .put("apiVersion", 1).put("method", "dispatch")
                .put("params", JSONObject().put("action", "closeGraph")
                    .put("payload", JSONObject().put("graphId", effect.text).toString()))
                .toString())
            val response = JSONObject(closed)
            if (!response.optBoolean("ok")) {
                runCoreRestore(hasAuthenticatedSession, platformEffects.loadStorageState())
                return NativeEffectResolution.Failure(response.optJSONObject("error")?.optString("message").orEmpty())
            }
            appliedServerT = -1L
            applyCoreResponse(closed)
        }
        val resolution = executor.execute(effect)
        if (resolution is NativeEffectResolution.CoreResponse) trackSyncState(resolution.response)
        if (deletingOpenGraph) {
            if (resolution.succeeded) {
                platformEffects.persistSelectedGraphId("")
                selectedGraphId = ""
            } else {
                runCoreRestore(hasAuthenticatedSession, platformEffects.loadStorageState())
            }
            updateCatalogPolling("delete-local-graph")
        }
        if (effect.kind == "save-settings" && resolution.succeeded) {
            val storage = platformEffects.loadStorageState()
            appearance = storage.settings.appearance
            darkTheme = storage.settings.darkTheme
            if (storage.baseUrl != storageBaseUrl) {
                graphCatalogAutoRefresh?.stopPeriodic()
                hasOpenGraph = false
                graphEventsSession.cancel()
                pendingSyncJob?.cancel()
                graphEventsSession.join()
                pendingSyncJob?.join()
                pendingSyncJob = null
                pendingSyncRequested = false
                selectedGraphId = ""
                appliedServerT = -1L
                storageBaseUrl = storage.baseUrl
                platformEffects.persistSelectedGraphId("")
                runCoreRestore(hasAuthenticatedSession, storage.copy(selectedGraphId = ""))
            }
        }
        if (effect.kind == "sign-in" && resolution.succeeded &&
            runCatching { JSONObject(resolution.message).optBoolean("signedIn") }.getOrDefault(false)) {
            restoreCore(hasStoredSession = true)
        }
        if (effect.kind == "sign-out" && resolution.succeeded) {
            hasAuthenticatedSession = false
            graphCatalogAutoRefresh?.stopPeriodic()
            graphEventsSession.cancel()
            pendingSyncJob?.cancel()
            graphEventsSession.join()
            pendingSyncJob?.join()
            pendingSyncJob = null
            pendingSyncRequested = false
            val payload = JSONObject()
                .put("baseUrl", storageBaseUrl)
                .put("graphId", selectedGraphId)
                .put("token", "")
                .toString()
            val cleared = bridge.callCore(JSONObject()
                .put("apiVersion", 1).put("method", "dispatch")
                .put("params", JSONObject().put("action", "configure").put("payload", payload))
                .toString())
            configuredAccessToken = ""
            applyCoreResponse(cleared)
        }
        if (resolution.succeeded &&
            effect.kind in setOf("open-graph", "unlock-graph", "create-graph")
        ) {
            hasOpenGraph = true
            resumeAudioRecording()
            appEntries.markReady()
            graphCatalogAutoRefresh?.stopPeriodic()
            requestSyncNow()
            // First post-open snapshots ship an empty sidebar; fill it
            // off the launch path once the journal is up.
            loadSidebarAfterOpen()
        }
        if (resolution.succeeded &&
            effect.kind in setOf("send-capture", "send-task", "send-tagged", "sync-now")
        ) {
            requestSyncNow()
        }
        return resolution
    }

    // --- Bootstrap / restore ---

    private fun loadSidebarAfterOpen() {
        scope.launch {
            try {
                graphLifecycle?.loadSidebar()?.let { applyCoreResponse(it) }
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                reportError(error)
            }
        }
    }

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
        try {
            val restoredAuthentication = restoreAndroidAuthentication(hasStoredSession, platformEffects::restoreAccessToken)
            hasAuthenticatedSession = restoredAuthentication.hasSession
            if (hasStoredSession && !restoredAuthentication.hasSession) {
                hostUpdate(
                    kind = "authentication",
                    payload = JSONObject()
                        .put("state", "signedOut")
                        .put("errorMessage", JSONObject.NULL)
                        .toString(),
                )
                AndroidLaunchMetrics.report("authentication_published")
            }
            if (restoredAuthentication.unavailable) {
                logRuntime("info", "core", "Authentication refresh unavailable; restoring cached state without a network token")
            }
            logRuntime("info", "core", "Restoring core state")
            val state = platformEffects.coreStartupState(restoredAuthentication.accessToken, storage)
            val restored = CoreBootstrap(
                callCore = bridge::callCore,
                trace = { traceGraphLifecycle("bootstrap $it") },
            ).restore(state)
            configuredAccessToken = restoredAuthentication.accessToken
            applyCoreResponse(restored.catalogResponse)
            graphCatalogAutoRefresh?.rememberCatalog(restored.catalogResponse)
            hostUpdate(
                kind = "local-graph-ids",
                payload = org.json.JSONArray(restored.localGraphIds).toString(),
            )
            hasOpenGraph = restored.graphResponse != null
            restored.graphResponse?.let { applyCoreResponse(it) }
            if (isOpeningInitialWidgetBlock) {
                try {
                    appEntries.deliverInitialWidgetBlocks(::reportWidgetLinkError)
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    reportWidgetLinkError(error)
                }
            }
            hostUpdate("graph-loading", "false")
            // The catalog patch carries the authentication snapshot the UI
            // renders against; by now auth state is published either way.
            AndroidLaunchMetrics.report("authentication_published")
            logRuntime("info", "core", "Core state restored")
            resumeAudioRecording()
            if (hasOpenGraph) {
                requestSyncNow()
                loadSidebarAfterOpen()
            }
            appEntries.markReady()
            updateCatalogPolling("restore")
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            reportError(error)
            hostUpdate("graph-loading", "false")
        } finally {
            isRestoringInitialGraph = false
            isOpeningInitialWidgetBlock = false
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

    private fun reportQueuedAppEntryError(error: Throwable) {
        if (error is AndroidAppEntryRejected &&
            (error.code == "outliner_effect_failed" || error.code == "outliner_command_failed")
        ) {
            reportWidgetLinkError(error)
        } else {
            reportError(error)
        }
    }

    private fun reportWidgetLinkError(error: Throwable) {
        reportError(error)
        LogseqDialogs.notifyError(error.message ?: "The linked block could not be opened.")
    }

    private suspend fun handleAppEntry(entry: AndroidAppEntry) {
        logRuntime("info", "ui", "Handling Android app entry ${entry.kind}")
        when (entry.kind) {
            AndroidAppEntryKind.OpenCapture ->
                hostUpdate("open-capture", "{}")
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
            AndroidAppEntryKind.SharedAsset -> {
                check(hasOpenGraph) { "Open a graph before adding a shared attachment" }
                addImportedAsset(requireNotNull(entry.asset), targetBlockId = null)
            }
        }
    }

    private suspend fun presentJournalCalendar(): NativeEffectResolution {
        val day = com.logseq.logseq.ui.extensions.LogseqDialogs.chooseJournalDate()
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

    private suspend fun applyAppEntryCoreRequest(request: String, allowGraphSwitch: Boolean = true) {
        val response = bridge.callCore(request)
        val decoded = JSONObject(response)
        if (!decoded.optBoolean("ok")) {
            val error = decoded.optJSONObject("error")
            val message = error?.optString("message")?.takeIf(String::isNotBlank)
            throw AndroidAppEntryRejected(message ?: "The native core rejected the Android app entry", error?.optString("code"))
        }
        applyCoreResponse(response)
        val result = decoded.optJSONObject("result")
        val graphID = result?.optString("deepLinkGraphId")?.takeIf { it.isNotEmpty() && it != "null" }
        if (graphID != null) {
            check(allowGraphSwitch) { "The linked graph did not finish opening" }
            val opened = executeEffect(NativeEffect(id = 0, kind = "open-graph", text = graphID))
            check(opened.succeeded) { opened.message }
            if (opened is NativeEffectResolution.CoreResponse) applyCoreResponse(opened.response)
            applyAppEntryCoreRequest(request, allowGraphSwitch = false)
            return
        }
        result?.optString("deepLinkNodeUuid")?.takeIf { it.isNotEmpty() && it != "null" }?.let { uuid ->
            hostUpdate("open-node", JSONObject.quote(uuid))
        }
        decoded.optJSONObject("result")?.optString("deepLinkQuickAction")?.takeIf(String::isNotEmpty)?.let { action ->
            hostUpdate("open-quick-action", JSONObject.quote(action))
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
        asset.requireAccepted(response)
        logRuntime("info", "core", "Added attachment ${asset.title}")
        applyCoreResponse(response)
    }

    suspend fun presentAudioRecording(targetBlockId: String?) {
        com.logseq.logseq.ui.extensions.LogseqDialogs.beginAudioRecording(targetBlockId, selectedGraphId)
        resumeAudioRecording()
    }

    private fun resumeAudioRecording() {
        val request = com.logseq.logseq.ui.extensions.LogseqDialogs.recordingRequest ?: return
        if (audioRecordingJob?.isActive == true) return
        audioRecordingJob = scope.launch {
            try {
                val recording = com.logseq.logseq.ui.extensions.LogseqDialogs.awaitAudioRecording(request)
                withContext(kotlinx.coroutines.NonCancellable) {
                    try {
                        if (recording != null) {
                            val (asset, transcript) = recording
                            check(hasOpenGraph && request.graphId == selectedGraphId) {
                                "The recording cannot be attached because its original graph is no longer open. Audio retained at ${asset.localPath}"
                            }
                            val response = bridge.callCore(asset.coreRequest(request.targetBlockId))
                            check(JSONObject(response).optBoolean("ok")) { "The native core rejected the recorded audio asset" }
                            applyCoreResponse(response)
                            if (!transcript.isNullOrBlank()) {
                                val transcriptResponse = bridge.callCore(asset.transcriptCoreRequest(transcript))
                                check(JSONObject(transcriptResponse).optBoolean("ok")) { "The native core rejected the recording transcript" }
                                applyCoreResponse(transcriptResponse)
                            }
                        }
                    } finally {
                        com.logseq.logseq.ui.extensions.LogseqDialogs.finishAudioRecording(request)
                    }
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reportError(error)
            }
        }
    }

    // --- Outliner platform commands ---

    private suspend fun handleOutlinerCommandBatch(batch: OutlinerPlatformCommandBatch) {
        for (command in batch.commands) {
            if (command.type.startsWith("setClipboard")) clipboardImageJob?.cancel()
            when (command.type) {
                "haptic" -> performHaptic(command.style)
                "confirmDelete" -> confirmDeletion(command.uuids)
                "setClipboardText" -> platformServices.copyText(command.text.orEmpty())
                "setClipboardBlocks" -> com.logseq.logseq.AndroidBlockClipboard.copy(activity, command.text.orEmpty())
                "setClipboardImages" -> command.imageClipboard?.let(::copyImages)
                "setClipboardReferences" -> platformServices.copyText(
                    command.uuids.joinToString("\n") { "[[$it]]" }
                )
                "setClipboardURLs" -> platformServices.copyText(
                    command.uuids.joinToString("\n") {
                        AndroidAppEntryParser.blockURL(batch.graphName.orEmpty(), it)
                    }
                )
                "pickAttachment" -> presentAttachment("files", command.uuid)
                "takePhoto" -> presentAttachment("camera", command.uuid)
                "recordAudio" -> presentAudioRecording(command.uuid)
                "focusBlock" -> Unit // autofocus handles it in the retained editor
            }
        }
    }

    private fun copyImages(clipboard: OutlinerPlatformCommand.ImageClipboard) {
        val timestamp = platformServices.clipboardTimestamp()
        clipboardImageJob = scope.launch {
            try {
                val paths = clipboard.images.map { image ->
                    graphAssetLoader.load(image.uuid, image.assetType, clipboard.graphId)
                }
                platformServices.copyImages(paths, replacing = timestamp)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reportError(error)
                LogseqDialogs.notifyError(error.message ?: "The image could not be copied")
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
        val confirmed = com.logseq.logseq.ui.extensions.LogseqDialogs
            .confirmDeletion(blockIds.size > 1)
        if (confirmed) {
            hostUpdate("confirm-outliner-delete", "null")
            effectDrain?.let { drain -> scope.launch { drain.drain(scope) } }
        }
    }

    // --- Tracing / logging ---

    private fun reportError(error: Throwable) {
        if (isNetworkUnavailable(error)) {
            logRuntime("info", "ui", "Network temporarily unavailable (${error.javaClass.simpleName})")
            Log.w("LogseqRuntime", "Network temporarily unavailable", error)
            return
        }
        logRuntime("error", "ui", error.toString())
        Log.e("LogseqRuntime", "Effect failed\n${error.stackTraceToString()}")
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
        if (ownsCore) {
            NativeCoreSession.syncActive = null
            NativeCoreSession.updateActiveWidgetTask = null
            NativeCoreSession.refreshActiveRandomWidget = null
        }
        runtimeJob.cancel()
        NativeCoreSession.cleanupScope.launch {
            runtimeJob.join()
            graphProgress = null
            if (ownsCore) {
                AndroidGraphImportProgress.listener = null
                try { withContext(NativeCoreThread.dispatcher) { bridge.close() } }
                finally {
                    ownsCore = false
                    NativeCoreSession.gate.unlock(this@LogseqRuntime)
                }
            }
        }
    }

    val effectiveAppearance: String get() = appearance
    val effectiveDarkTheme: String get() = darkTheme
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
