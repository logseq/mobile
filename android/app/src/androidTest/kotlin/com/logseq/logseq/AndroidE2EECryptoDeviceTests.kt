package com.logseq.logseq

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidE2EECryptoDeviceTests {
    @Test
    fun secureStorageRoundTripsTheGlobalPasswordAndPerGraphKeys() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("logseq.e2ee.secure-storage", 0).edit().clear().commit()
        AndroidE2EECrypto.initialize(context)

        assertNull(value(call("""{"operation":"loadE2EEPassword"}""")))
        assertNull(value(call("""{"operation":"loadGraphKey","graphID":"first"}""")))

        call("""{"operation":"saveE2EEPassword","password":"70617373776f7264"}""")
        call("""{"operation":"saveGraphKey","graphID":"first","key":"${"11".repeat(32)}"}""")
        call("""{"operation":"saveGraphKey","graphID":"second","key":"${"22".repeat(32)}"}""")

        assertEquals("70617373776f7264", value(call("""{"operation":"loadE2EEPassword"}""")))
        assertEquals("11".repeat(32), value(call("""{"operation":"loadGraphKey","graphID":"first"}""")))
        assertEquals("22".repeat(32), value(call("""{"operation":"loadGraphKey","graphID":"second"}""")))
    }

    private fun call(request: String): JSONObject = JSONObject(AndroidE2EECrypto.call(request)).also {
        assertEquals(it.optString("error"), true, it.getBoolean("ok"))
    }

    private fun value(response: JSONObject): String? =
        if (response.isNull("value")) null else response.getString("value")
}
