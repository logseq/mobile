package com.logseq.app.runtime

import com.logseq.app.AndroidPlatformServices
import com.logseq.app.CognitoAuthProvider
import com.logseq.app.DEFAULT_BASE_URL
import org.json.JSONArray
import org.json.JSONObject

// Kotlin port of the former android_platform_effects.dart. The previous
// version reached these through MethodChannels; here the Kotlin platform
// services are called directly — same operations, same SharedPreferences
// keys, same payloads.
internal interface AndroidAuthentication {
    fun hasStoredSession(): Boolean
    suspend fun restoreAccessToken(): String?
    suspend fun signIn(): String
    suspend fun signOut(): Unit
}

internal class CognitoAndroidAuthentication(
    private val provider: CognitoAuthProvider,
) : AndroidAuthentication {
    override fun hasStoredSession(): Boolean = provider.hasStoredSession()
    override suspend fun restoreAccessToken(): String? = provider.apiToken()
    override suspend fun signIn(): String = provider.signIn()
    override suspend fun signOut() = provider.signOut()
}

internal data class AndroidStorageState(
    val databasePath: String,
    val graphsDirectory: String,
    val baseUrl: String,
    val selectedGraphId: String,
    val localGraphIds: List<String>,
    val settings: AndroidHostSettings = AndroidHostSettings.defaults,
    val composerDraft: String = "",
) {
    val startupHostUpdates: List<AndroidHostUpdate>
        get() = listOf(
            AndroidHostUpdate(kind = "graph-loading", payload = "true"),
            AndroidHostUpdate(
                kind = "settings",
                payload = JSONObject(settings.hostPayload).toString(),
            ),
            AndroidHostUpdate(
                kind = "composer-draft",
                payload = JSONObject.quote(composerDraft),
            ),
        )

    companion object {
        fun fromPlatformMap(value: Map<String, Any?>): AndroidStorageState {
            @Suppress("UNCHECKED_CAST")
            val settings = value["settings"] as? Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val localGraphIds = (value["localGraphIds"] as? List<Any?>)
                ?.mapNotNull { it as? String } ?: emptyList()
            return AndroidStorageState(
                databasePath = value["databasePath"] as? String ?: "",
                graphsDirectory = value["graphsDirectory"] as? String ?: "",
                baseUrl = value["baseUrl"] as? String ?: DEFAULT_BASE_URL,
                selectedGraphId = value["selectedGraphId"] as? String ?: "",
                localGraphIds = localGraphIds,
                settings = AndroidHostSettings.fromPlatformValue(settings),
                composerDraft = value["composerDraft"] as? String ?: "",
            )
        }
    }
}

internal data class AndroidHostUpdate(val kind: String, val payload: String)

internal data class AndroidHostSettings(
    val appearance: String,
    val language: String,
    val spellCheck: Boolean,
    val autoCorrection: Boolean,
    val sidebarTabs: List<String>,
    val baseUrl: String,
    val version: String,
    val revision: String,
) {
    val hostPayload: Map<String, Any?>
        get() = mapOf(
            "appearance" to appearance,
            "language" to language,
            "spellCheck" to spellCheck,
            "autoCorrection" to autoCorrection,
            "sidebarTabs" to sidebarTabs,
            "baseURL" to baseUrl,
            "version" to version,
            "revision" to revision,
        )

    companion object {
        val defaults = AndroidHostSettings(
            appearance = "system",
            language = "system",
            spellCheck = true,
            autoCorrection = true,
            sidebarTabs = emptyList(),
            baseUrl = DEFAULT_BASE_URL,
            version = "Development",
            revision = "Development",
        )

        fun fromPlatformValue(value: Map<String, Any?>?): AndroidHostSettings {
            if (value == null) return defaults
            @Suppress("UNCHECKED_CAST")
            val tabs = (value["sidebarTabs"] as? List<Any?>)
                ?.mapNotNull { it as? String } ?: defaults.sidebarTabs
            return AndroidHostSettings(
                appearance = value["appearance"] as? String ?: defaults.appearance,
                language = value["language"] as? String ?: defaults.language,
                spellCheck = value["spellCheck"] as? Boolean ?: defaults.spellCheck,
                autoCorrection = value["autoCorrection"] as? Boolean ?: defaults.autoCorrection,
                sidebarTabs = tabs,
                baseUrl = value["baseURL"] as? String ?: defaults.baseUrl,
                version = value["version"] as? String ?: defaults.version,
                revision = value["revision"] as? String ?: defaults.revision,
            )
        }
    }
}

internal data class AndroidDownloadedSnapshot(
    val metadataBody: String,
    val filePath: String,
)

internal class AndroidPlatformEffects(
    private val authentication: AndroidAuthentication,
    private val platform: AndroidPlatformServices,
    private val attachmentsImporter: suspend (String) -> List<Map<String, Any>>,
    private val syncNow: () -> Boolean = { false },
    private val presentJournalCalendar: suspend () -> NativeEffectResolution = {
        NativeEffectResolution.Discard(succeeded = false, message = "Journal calendar is unavailable")
    },
) : AndroidGraphStorage {
    suspend fun initialAuthenticationCode(): Int = try {
        if (authentication.hasStoredSession()) 3 else 1
    } catch (_: Throwable) {
        1
    }

    suspend fun restoreAccessToken(): String? = authentication.restoreAccessToken()

    override fun loadStorageState(): AndroidStorageState =
        AndroidStorageState.fromPlatformMap(platform.loadStorageState())

    suspend fun coreStartupState(
        accessToken: String,
        storage: AndroidStorageState? = null,
    ): CoreStartupState {
        val resolved = storage ?: loadStorageState()
        return CoreStartupState(
            databasePath = resolved.databasePath,
            graphsDirectory = resolved.graphsDirectory,
            baseUrl = resolved.baseUrl,
            selectedGraphId = resolved.selectedGraphId,
            localGraphIds = resolved.localGraphIds,
            accessToken = accessToken,
        )
    }

    suspend fun execute(effect: NativeEffect): NativeEffectResolution = try {
        when (effect.kind) {
            "present-journal-calendar" -> presentJournalCalendar()
            "persist-composer-draft" -> {
                platform.persistComposerDraft(effect.text)
                NativeEffectResolution.Discard()
            }
            "save-settings" -> {
                platform.saveSettings(effect.text)
                NativeEffectResolution.Discard()
            }
            "open-external-url" -> NativeEffectResolution.Discard(
                succeeded = platform.openExternalUrl(effect.text),
            )
            "copy-runtime-log" -> {
                platform.copyText(runtimeLogText(effect.text))
                NativeEffectResolution.Discard()
            }
            "refresh-runtime-log" -> {
                val records = platform.refreshRuntimeLog(
                    source = effect.text,
                    flags = (effect.value ?: 0).toInt(),
                )
                NativeEffectResolution.HostUpdate(kind = "runtime-log", payload = records)
            }
            "present-attachment" -> NativeEffectResolution.Discard(
                succeeded = platform.presentAttachment(effect.text),
            )
            "present-asset" -> NativeEffectResolution.Discard(
                succeeded = platform.presentAsset(effect.metadata ?: ""),
            )
            "present-page-share" -> NativeEffectResolution.Discard(
                succeeded = platform.presentPageShare(
                    text = effect.text,
                    metadata = effect.metadata ?: "[]",
                ),
            )
            "sync-now", "sync-pending" -> NativeEffectResolution.Discard(succeeded = syncNow())
            "delete-local-graph" -> NativeEffectResolution.Discard(
                succeeded = platform.deleteLocalGraph(effect.text),
            )
            "export-graph-database" -> NativeEffectResolution.Discard(
                succeeded = platform.exportGraphDatabase(),
            )
            "sign-in" -> {
                val token = authentication.signIn()
                if (token.isBlank()) {
                    NativeEffectResolution.Discard(
                        succeeded = false,
                        message = "Hosted sign-in did not return an access token",
                    )
                } else {
                    NativeEffectResolution.Discard()
                }
            }
            "sign-out" -> {
                authentication.signOut()
                NativeEffectResolution.Discard()
            }
            else -> NativeEffectResolution.Discard(
                succeeded = false,
                message = "Unsupported Android platform effect: ${effect.kind}",
            )
        }
    } catch (error: Throwable) {
        NativeEffectResolution.Failure(error.toString())
    }

    // Called through by the runtime for effect kinds handled in the app
    // layer rather than the platform services (attachment pickers, audio
    // recording) — the Kotlin importer returns the same map shape the
    // MethodChannel produced.
    suspend fun importAttachments(kind: String): List<Map<String, Any>> =
        attachmentsImporter(kind)

    override suspend fun downloadGraphSnapshot(
        baseUrl: String,
        graphId: String,
        accessToken: String,
        workingDirectory: String,
        callCore: suspend (String) -> String,
        onProgress: (String, Long, Long?) -> Unit,
    ): AndroidDownloadedSnapshot {
        val value = platform.downloadGraphSnapshot(baseUrl, graphId, accessToken, workingDirectory, callCore, onProgress)
        return AndroidDownloadedSnapshot(
            metadataBody = value["metadataBody"] ?: error("Android did not return snapshot metadata"),
            filePath = value["filePath"] ?: error("Android did not return a snapshot path"),
        )
    }

    override fun persistSelectedGraphId(graphId: String) = platform.persistSelectedGraphId(graphId)
    override fun deleteTemporaryFile(path: String) = platform.deleteTemporaryFile(path)
    fun resolveAssetPath(path: String): String = platform.resolveAssetPath(path)
    fun appendRuntimeLog(level: String, source: String, message: String) {
        platform.appendRuntimeLog(level, source, message)
    }

    private fun runtimeLogText(encoded: String): String {
        val decoded = JSONArray(encoded)
        return (0 until decoded.length()).joinToString("\n") { index ->
            val entry = decoded.getJSONObject(index)
            listOf("timestamp", "level", "source", "message")
                .map { entry.optString(it) }
                .filter(String::isNotEmpty)
                .joinToString(" ")
        }
    }
}
