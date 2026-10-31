package com.logseq.app.runtime

import android.util.Log
import com.logseq.app.NativeCore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// JNI bridge into liblogseq_core.so — the Kotlin port of
// the former logseq_native_bridge.dart.
//
// LUI event calls run through the scheduler's UI lane so patches
// produced mid-flight cannot interleave with a busy core RPC; the effect
// entry points (takeEffect / resolveEffect / applySnapshot /
// applyHostUpdate) return "" and re-queue while the core is busy.
// `call` runs the blocking JNI call on Dispatchers.Default, matching the
// Dart implementation's worker-isolate call.
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
        apply(decode(NativeCore.luiInitialize(platformCode, hostCode, authenticationCode)))
        return NativeCore.luiRootNode()
    }

    fun close() = runtimeScheduler.runUi { apply(decode(NativeCore.luiDispose())) }

    fun resync(onSnapshot: (String) -> Unit) = runtimeScheduler.runUi {
        onSnapshot(decode(NativeCore.luiResync()))
    }

    fun appear(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiAppear(node))) }
    fun press(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiPress(node))) }
    fun longPress(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiLongPress(node))) }
    fun submit(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiSubmit(node))) }
    fun change(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiChange(node))) }
    fun dismiss(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiDismiss(node))) }
    fun doublePress(node: Long) = runtimeScheduler.runUi { apply(decode(NativeCore.luiDoublePress(node))) }

    fun textChanged(node: Long, text: String) = runtimeScheduler.runUi {
        apply(decode(NativeCore.luiTextChanged(node, encode(text))))
    }

    fun toggleChanged(node: Long, checked: Boolean) = runtimeScheduler.runUi {
        apply(decode(NativeCore.luiToggleChanged(node, if (checked) 1 else 0)))
    }

    fun valueChanged(node: Long, value: Double) = runtimeScheduler.runUi {
        apply(decode(NativeCore.luiValueChanged(node, value)))
    }

    fun picked(node: Long, payload: String) = runtimeScheduler.runUi {
        apply(decode(NativeCore.luiPicked(node, encode(payload))))
    }

    fun visibleRange(node: Long, first: Long, last: Long) = runtimeScheduler.runUi {
        apply(decode(NativeCore.luiVisibleRange(node, first, last)))
    }

    fun scrollCompleted(node: Long, token: Long, outcome: String) = runtimeScheduler.runUi {
        apply(decode(NativeCore.luiScrollCompleted(node, token, encode(outcome))))
    }

    fun extensionEvent(
        node: Long,
        identifier: String,
        name: String,
        text: String,
        value: Long,
    ) = runtimeScheduler.runUi {
        apply(
            decode(
                NativeCore.luiExtensionEvent(
                    node,
                    encode(identifier),
                    encode(name),
                    encode(text),
                    value,
                )
            )
        )
    }

    // --- NativeEffectRuntime surface ---

    fun takeEffect(): String =
        if (runtimeScheduler.isCoreBusy) "" else decode(NativeCore.luiTakeEffect())

    fun resolveEffect(id: Long, succeeded: Boolean, message: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi {
                apply(decode(NativeCore.luiResolveEffect(id, if (succeeded) 1 else 0, encode(message))))
            }
            return ""
        }
        return decode(NativeCore.luiResolveEffect(id, if (succeeded) 1 else 0, encode(message)))
    }

    fun applySnapshot(response: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi {
                apply(decode(NativeCore.luiApplySnapshot(encode(response))))
            }
            return ""
        }
        return decode(NativeCore.luiApplySnapshot(encode(response)))
    }

    fun applyHostUpdate(kind: String, payload: String): String {
        if (runtimeScheduler.isCoreBusy) {
            runtimeScheduler.runUi {
                apply(decode(NativeCore.luiApplyHostUpdate(encode(kind), encode(payload))))
            }
            return ""
        }
        return decode(NativeCore.luiApplyHostUpdate(encode(kind), encode(payload)))
    }

    // Core RPC ({apiVersion:1, method:open|dispatch, params:{...}}) —
    // blocking JNI call on a background thread, serialized on the core lane.
    suspend fun callCore(request: String): String =
        runtimeScheduler.runCore {
            withContext(Dispatchers.Default) {
                decode(NativeCore.logseqCall(encode(request)))
            }
        }

    fun isLinked(): Boolean = runCatching {
        NativeCore.luiRootNode()
        true
    }.getOrElse {
        Log.w(TAG, "liblogseq_core is not linked", it)
        false
    }

    private companion object {
        const val TAG = "LogseqBridge"
    }
}
