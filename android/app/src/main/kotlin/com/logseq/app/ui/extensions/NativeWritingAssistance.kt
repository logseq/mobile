package com.logseq.app.ui.extensions

import android.content.Context
import android.content.SharedPreferences
import android.text.InputType
import androidx.compose.runtime.*
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.platform.PlatformTextInputMethodRequest

@Composable
internal fun NativeWritingAssistance(content: @Composable () -> Unit) {
    val context = LocalContext.current.applicationContext
    val preferences = remember(context) { context.getSharedPreferences("logseq", Context.MODE_PRIVATE) }
    fun readSettings() = preferences.getBoolean("logseq.editor.autoCorrection", true) to
        preferences.getBoolean("logseq.editor.spellCheck", true)
    var settings by remember(preferences) { mutableStateOf(readSettings()) }
    DisposableEffect(preferences) {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "logseq.editor.autoCorrection" || key == "logseq.editor.spellCheck" || key == null)
                settings = readSettings()
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        onDispose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    // Retain the interceptor while typing; only a preference change restarts the IME session.
    val interceptor = remember(settings) {
        PlatformTextInputInterceptor { request, next ->
            next.startInputMethod(PlatformTextInputMethodRequest { attributes ->
                val connection = request.createInputConnection(attributes)
                attributes.inputType = if (settings.first)
                    attributes.inputType or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
                else attributes.inputType and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT.inv()
                // Android's no-suggestions flag also overrides autocorrection in the IME.
                attributes.inputType = if (settings.second)
                    attributes.inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS.inv()
                else attributes.inputType or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                connection
            })
        }
    }
    InterceptPlatformTextInput(interceptor, content)
}
