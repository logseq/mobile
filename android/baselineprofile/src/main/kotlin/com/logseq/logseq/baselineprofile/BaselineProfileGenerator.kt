package com.logseq.logseq.baselineprofile

import android.os.SystemClock
import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Records startup and the journal home screen: cold launch, scrolling the
 * journal list, and the sidebar.
 *
 * Requires a signed-in device with an open graph. The journey never touches
 * blocks, so it leaves the graph unchanged.
 */
@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {
    @get:Rule val rule = BaselineProfileRule()

    @Test fun journalHome() = rule.collect(packageName = PACKAGE, includeInStartupProfile = true) {
        pressHome()
        startActivityAndWait()
        device.wait(Until.hasObject(By.res("list.outliner")), 15_000)
        val x = device.displayWidth / 2
        val (top, bottom) = device.displayHeight / 4 to device.displayHeight * 3 / 4
        repeat(4) {
            device.swipe(x, bottom, x, top, 10)
            SystemClock.sleep(400)
        }
        repeat(4) {
            device.swipe(x, top, x, bottom, 10)
            SystemClock.sleep(400)
        }
        device.findObject(By.res("button.sidebar"))?.let { sidebar ->
            sidebar.click()
            SystemClock.sleep(800)
            device.pressBack()
            SystemClock.sleep(800)
        }
    }

    private companion object {
        const val PACKAGE = "com.logseq.logseq"
    }
}
