package com.logseq.app

// JNI entry points into liblogseq_core.so, exposed through the
// logseq_jni shim library (app/src/main/cpp/logseq_jni.c).
//
// Every string payload crosses as raw UTF-8 bytes: the core speaks
// standard UTF-8, so bypassing modified-UTF-8 jstrings keeps emoji and
// other 4-byte sequences intact. A null return means the native call
// failed to produce a response (the core returns an empty string on
// error, which likewise maps to null on the Kotlin side).
internal object NativeCore {
    init {
        // Let the JVM run JNI_OnLoad for the HTTPS and crypto callbacks.
        // The shim's dlopen only resolves C symbols and does not initialize JNI.
        System.loadLibrary("logseq_core")
        System.loadLibrary("logseq_jni")
        check(installGraphImportProgressCallback(com.logseq.app.runtime.AndroidGraphImportProgress::class.java)) {
            "The native core does not support graph import progress"
        }
    }

    private external fun installGraphImportProgressCallback(receiver: Class<*>): Boolean

    external fun luiInitialize(platform: Int, host: Int, authentication: Int): ByteArray?
    external fun luiRootNode(): Long
    external fun luiAppear(node: Long): ByteArray?
    external fun luiPress(node: Long): ByteArray?
    external fun luiLongPress(node: Long): ByteArray?
    external fun luiSubmit(node: Long): ByteArray?
    external fun luiChange(node: Long): ByteArray?
    external fun luiDismiss(node: Long): ByteArray?
    external fun luiDoublePress(node: Long): ByteArray?
    external fun luiTextChanged(node: Long, text: ByteArray): ByteArray?
    external fun luiToggleChanged(node: Long, checked: Int): ByteArray?
    external fun luiValueChanged(node: Long, value: Double): ByteArray?
    external fun luiPicked(node: Long, payload: ByteArray): ByteArray?
    external fun luiVisibleRange(node: Long, first: Long, last: Long): ByteArray?
    external fun luiScrollCompleted(node: Long, token: Long, outcome: ByteArray): ByteArray?
    external fun luiExtensionEvent(
        node: Long,
        identifier: ByteArray,
        name: ByteArray,
        text: ByteArray,
        value: Long,
    ): ByteArray?
    external fun luiDispose(): ByteArray?
    external fun luiResync(): ByteArray?
    external fun luiTakeEffect(): ByteArray?
    external fun luiResolveEffect(effectId: Long, succeeded: Int, message: ByteArray): ByteArray?
    external fun luiApplySnapshot(response: ByteArray): ByteArray?
    external fun luiApplyHostUpdate(kind: ByteArray, payload: ByteArray): ByteArray?
    external fun logseqCall(request: ByteArray): ByteArray?
    external fun highlightCode(request: ByteArray): ByteArray?
}
