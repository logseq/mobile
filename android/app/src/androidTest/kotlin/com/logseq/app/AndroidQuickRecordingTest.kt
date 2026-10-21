package com.logseq.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import android.net.Uri
import android.service.quicksettings.TileService
import android.view.LayoutInflater
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidQuickRecordingTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun audioDeepLinkAndLauncherShortcutResolveToTheMainActivity() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("logseq://audio")).addCategory(Intent.CATEGORY_BROWSABLE).setPackage(context.packageName)
        assertEquals(MainActivity::class.java.name, context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.name)
        val shortcuts = context.getSystemService(ShortcutManager::class.java).manifestShortcuts
        assertTrue(shortcuts.any { it.id == "capture" })
        assertTrue(shortcuts.any { it.id == "journal" })
        val audio = shortcuts.single { it.id == "audio" }
        assertEquals("logseq://audio", audio.intent?.dataString)
        assertEquals(MainActivity::class.java.name, audio.intent?.component?.className)
    }

    @Test fun quickSettingsExposesAProtectedNativeRecordingTile() {
        val intent = Intent(TileService.ACTION_QS_TILE).setPackage(context.packageName)
        val service = context.packageManager.queryIntentServices(intent, PackageManager.GET_META_DATA).single().serviceInfo
        assertTrue(service.exported)
        assertEquals(Manifest.permission.BIND_QUICK_SETTINGS_TILE, service.permission)
        assertTrue(service.icon != 0)
        assertEquals("Record audio", service.loadLabel(context.packageManager).toString())
    }

    @Test fun captureWidgetHasASeparateAccessibleRecordingAction() {
        val layout = LayoutInflater.from(context).inflate(R.layout.widget_capture, null)
        val id = context.resources.getIdentifier("widget_capture_audio", "id", context.packageName)
        assertTrue("The capture widget needs a recording action", id != 0)
        val action = requireNotNull(layout.findViewById<View>(id))
        assertEquals("Record audio", action.contentDescription.toString())
        assertTrue(action.isClickable)
        assertTrue(action.isFocusable)
    }
}
