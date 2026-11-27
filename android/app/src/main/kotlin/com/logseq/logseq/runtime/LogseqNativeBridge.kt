package com.logseq.logseq.runtime

import android.os.Build
import android.os.Trace
import android.util.Log
import com.logseq.logseq.NativeCore
import kotlinx.coroutines.withContext

// JNI bridge into liblogseq_core.so — the Kotlin port of
// the former logseq_native_bridge.dart.
//
// LUI event calls run through the scheduler's UI lane so patches
// produced mid-flight cannot interleave with a busy core RPC; the effect
// entry points can return an empty patch while the core is busy.
// `callCore` runs on NativeCoreThread, the same thread the runtime uses for
// every other core entry point.
internal class LogseqNativeBridge(
    private val onPatch: (String) -> Unit = {},
    private val runtimeScheduler: NativeRuntimeScheduler = NativeRuntimeScheduler(),
) {
    var onCoreIdle: (() -> Unit)?
        get() = runtimeScheduler.onIdle
        set(value) {
            runtimeScheduler.onIdle = value
        }

    val scheduler: NativeRuntimeScheduler get() = runtimeScheduler

    private fun decode(bytes: ByteArray?): String = bytes?.toString(Charsets.UTF_8).orEmpty()

    private fun encode(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    private fun apply(patch: String) {
        if (patch.isNotEmpty()) onPatch(patch)
    }

    // platform 3 = AndroidOS, host 4 = KotlinHost (see the host-code table
    // in shared/src/logseq/native_bridge.ml, matching lui's
    // components_bridge.ml).
    fun initialize(
        platformCode: Int = 3,
        hostCode: Int = 4,
        authenticationCode: Int = 1,
    ): Long {
        apply(decode(traced("core.luiInitialize") { NativeCore.luiInitialize(platformCode, hostCode, authenticationCode) }))
        return NativeCore.luiRootNode()
    }

    fun close() = runtimeScheduler.runUi { apply(decode(traced("core.luiDispose") { NativeCore.luiDispose() })) }

    fun resync(onSnapshot: (String) -> Unit) = runtimeScheduler.runUi {
        onSnapshot(decode(traced("core.luiResync") { NativeCore.luiResync() }))
    }

    fun appear(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiAppear") { NativeCore.luiAppear(node) })) }
    fun press(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiPress") { NativeCore.luiPress(node) })) }
    fun longPress(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiLongPress") { NativeCore.luiLongPress(node) })) }
    fun submit(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiSubmit") { NativeCore.luiSubmit(node) })) }
    fun change(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiChange") { NativeCore.luiChange(node) })) }
    fun dismiss(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiDismiss") { NativeCore.luiDismiss(node) })) }
    fun doublePress(node: Long) = runtimeScheduler.runUi { apply(decode(traced("core.luiDoublePress") { NativeCore.luiDoublePress(node) })) }

    fun textChanged(node: Long, text: String) = runtimeScheduler.runUi {
        apply(decode(traced("core.luiTextChanged") { NativeCore.luiTextChanged(node, encode(text)) }))
    }

    fun toggleChanged(node: Long, checked: Boolean) = runtimeScheduler.runUi {
        apply(decode(traced("core.luiToggleChanged") { NativeCore.luiToggleChanged(node, if (checked) 1 else 0) }))
    }

    fun valueChanged(node: Long, value: Double) = runtimeScheduler.runUi {
        apply(decode(traced("core.luiValueChanged") { NativeCore.luiValueChanged(node, value) }))
    }

    fun picked(node: Long, payload: String) = runtimeScheduler.runUi {
        apply(decode(traced("core.luiPicked") { NativeCore.luiPicked(node, encode(payload)) }))
    }

    fun visibleRange(node: Long, first: Long, last: Long) = runtimeScheduler.runUi {
        apply(decode(traced("core.luiVisibleRange") { NativeCore.luiVisibleRange(node, first, last) }))
    }

    fun scrollCompleted(node: Long, token: Long, outcome: String) = runtimeScheduler.runUi {
        apply(decode(traced("core.luiScrollCompleted") { NativeCore.luiScrollCompleted(node, token, encode(outcome)) }))
    }

    fun extensionEvent(
        node: Long,
        identifier: String,
        name: String,
        text: String,
        value: Long,
    ) = runtimeScheduler.runUi {
        val patch = decode(
            traced("core.luiExtensionEvent") {
                NativeCore.luiExtensionEvent(
                    node,
                    encode(identifier),
                    encode(name),
                    encode(text),
                    value,
                )
            }
        )
        apply(patch)
    }

    // --- NativeEffectRuntime surface ---

    fun takeEffect(): String {
        if (runtimeScheduler.isCoreBusy) return ""
        return decode(traced("core.luiTakeEffect") { NativeCore.luiTakeEffect() })
    }

    fun resolveEffect(id: Long, succeeded: Boolean, message: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi {
                apply(decode(traced("core.luiResolveEffect") { NativeCore.luiResolveEffect(id, if (succeeded) 1 else 0, encode(message)) }))
            }
            return ""
        }
        return decode(traced("core.luiResolveEffect") { NativeCore.luiResolveEffect(id, if (succeeded) 1 else 0, encode(message)) })
    }

    fun applySnapshot(response: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi {
                apply(decode(traced("core.luiApplySnapshot") { NativeCore.luiApplySnapshot(encode(response)) }))
            }
            return ""
        }
        return decode(traced("core.luiApplySnapshot") { NativeCore.luiApplySnapshot(encode(response)) })
    }

    fun completeEffectWithResponse(id: Long, response: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi { apply(completeEffectWithResponse(id, response)) }
            return ""
        }
        return decode(traced("core.luiCompleteEffectWithResponse") {
            NativeCore.luiCompleteEffectWithResponse(id, encode(response))
        })
    }

    fun applyHostUpdate(kind: String, payload: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi {
                apply(decode(traced("core.luiApplyHostUpdate") { NativeCore.luiApplyHostUpdate(encode(kind), encode(payload)) }))
            }
            return ""
        }
        return decode(traced("core.luiApplyHostUpdate") { NativeCore.luiApplyHostUpdate(encode(kind), encode(payload)) })
    }

    // Core RPC ({apiVersion:1, method:open|dispatch, params:{...}}) —
    // blocking JNI call on a background thread, serialized on the core lane.
    suspend fun callCore(request: String): String =
        withContext(NativeCoreThread.dispatcher) {
            runtimeScheduler.runCore {
                decode(traced("core.logseqCall:" + rpcMethod(request)) { NativeCore.logseqCall(encode(request)) })
            }
        }

    suspend fun callCoreAndApplySnapshot(request: String, onPatchApplied: (String) -> Unit): String =
        withContext(NativeCoreThread.dispatcher) {
            runtimeScheduler.runCore {
                val res = decode(traced("core.logseqCall:" + rpcMethod(request)) { NativeCore.logseqCall(encode(request)) })
                onPatchApplied(applySnapshot(res))
                res
            }
        }

    fun isLinked(): Boolean = runCatching {
        NativeCore.luiRootNode()
        true
    }.getOrElse {
        Log.w(TAG, "liblogseq_core is not linked", it)
        false
    }

    private fun rpcMethod(request: String): String =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || !Trace.isEnabled()) ""
        else RPC_METHOD.find(request)?.groupValues?.get(1) ?: "unknown"

    private companion object {
        const val TAG = "LogseqBridge"
        val RPC_METHOD = Regex("\"method\"\\s*:\\s*\"([^\"]+)\"")
    }
}
