package com.logseq.logseq

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.view.Window
import androidx.core.view.WindowCompat

internal fun androidAppearanceIsDark(appearance: String, configuration: Configuration): Boolean =
    when (appearance) {
        "dark" -> true
        "light" -> false
        else -> configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }

internal fun applyAndroidApplicationAppearance(context: Context, appearance: String) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        // Persist the app's choice in Android as well as our settings so the
        // system-owned starting window uses the right theme on the next launch.
        // AUTO clears the application override and follows the system mode.
        context.getSystemService(UiModeManager::class.java)?.setApplicationNightMode(
            when (appearance) {
                "dark" -> UiModeManager.MODE_NIGHT_YES
                "light" -> UiModeManager.MODE_NIGHT_NO
                else -> UiModeManager.MODE_NIGHT_AUTO
            },
        )
    }
}

internal fun applyAndroidSystemBarAppearance(window: Window, dark: Boolean) {
    // These colors are honored on pre-edge-to-edge releases. Newer Android
    // versions draw the app's Scaffold behind the transparent system bars.
    @Suppress("DEPRECATION")
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
        val background = if (dark) 0xff101318.toInt() else 0xfffcfcfc.toInt()
        window.statusBarColor = background
        window.navigationBarColor = background
    }
    WindowCompat.getInsetsController(window, window.decorView).apply {
        isAppearanceLightStatusBars = !dark
        isAppearanceLightNavigationBars = !dark
    }
}
