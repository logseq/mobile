package com.logseq.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.Gainmap
import android.graphics.Paint
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.log10

@RunWith(AndroidJUnit4::class)
class AndroidImageCompressionInstrumentedTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File

    @Before fun setup() { root = File(context.cacheDir, "compression-${System.nanoTime()}").apply { mkdirs() } }
    @After fun cleanup() { root.setWritable(true); root.deleteRecursively() }

    @Test fun compressesPhotosWithMeasuredQualityAndNeverUpscales() {
        val source = photo()
        val result = prepare(source)
        assertTrue("Must save at least 10%", result.file.length() < source.length() * 9 / 10)
        val actual = BitmapFactory.decodeFile(result.file.path)!!
        val original = BitmapFactory.decodeFile(source.path)!!
        val reference = Bitmap.createScaledBitmap(original, 2560, 1920, true)
        original.recycle()
        try {
            assertEquals(2560, actual.width)
            assertEquals(1920, actual.height)
            val psnr = psnr(reference, actual, 1)
            assertTrue("JPEG PSNR must exceed 35dB: $psnr", psnr > 35)
            Log.i("CompressionEvidence", "photo: ${source.length()} -> ${result.file.length()} bytes, PSNR=$psnr dB")
            File(context.getExternalFilesDir(null), "image-compression-evidence").apply { mkdirs() }.let { evidence ->
                source.copyTo(File(evidence, "photo-before.jpg"), overwrite = true)
                result.file.copyTo(File(evidence, "photo-after.jpg"), overwrite = true)
                File(evidence, "quality.txt").writeText("${source.length()} -> ${result.file.length()} bytes; PSNR=$psnr dB\n")
            }
        } finally { actual.recycle(); reference.recycle() }
        val small = image("Small.jpg", 300, 200, Bitmap.CompressFormat.JPEG)
        assertOriginal(small)
        val intermediate = photo(width = 2000, height = 1500)
        val prepared = prepare(intermediate)
        val bounds = dimensions(prepared.file)
        assertEquals(2000 to 1500, bounds)
        InstrumentationRegistry.getArguments().getString("landscape")?.let { path ->
            val landscape = File(path)
            assertTrue("Landscape fixture must be readable", landscape.isFile)
            val preparedLandscape = prepare(landscape)
            val decodedLandscape = BitmapFactory.decodeFile(landscape.path)!!
            val max = maxOf(decodedLandscape.width, decodedLandscape.height)
            val expectedLandscape = Bitmap.createScaledBitmap(decodedLandscape,
                decodedLandscape.width * 2560 / max, decodedLandscape.height * 2560 / max, true)
            decodedLandscape.recycle()
            val actualLandscape = BitmapFactory.decodeFile(preparedLandscape.file.path)!!
            try {
                val quality = psnr(expectedLandscape, actualLandscape, 1)
                assertTrue(quality > 35)
                assertTrue(preparedLandscape.file.length() < landscape.length() * 9 / 10)
                Log.i("CompressionEvidence", "landscape: ${landscape.length()} -> ${preparedLandscape.file.length()} bytes, PSNR=$quality dB")
                val evidence = File(context.getExternalFilesDir(null), "image-compression-evidence")
                preparedLandscape.file.copyTo(File(evidence, "landscape-after.jpg"), overwrite = true)
                File(evidence, "landscape-quality.txt").writeText("${landscape.length()} -> ${preparedLandscape.file.length()} bytes; PSNR=$quality dB\n")
            } finally {
                actualLandscape.recycle(); expectedLandscape.recycle()
                if (preparedLandscape.file != landscape) preparedLandscape.file.delete()
            }
        }
    }

    @Test fun normalizesAllEightExifOrientationsIncludingMirrors() {
        val source = photo()
        val decoded = BitmapFactory.decodeFile(source.path)!!
        val reference = Bitmap.createScaledBitmap(decoded, 2560, 1920, true)
        decoded.recycle()
        try {
            for (orientation in 1..8) {
                val oriented = source.copyTo(File(root, "orientation-$orientation.jpg"))
                ExifInterface(oriented.path).apply {
                    setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
                    saveAttributes()
                }
                val output = prepare(oriented).file
                assertTrue(output.length() < oriented.length() * 9 / 10)
                val actual = BitmapFactory.decodeFile(output.path)!!
                try {
                    assertEquals(if (orientation >= 5) 1920 else 2560, actual.width)
                    assertEquals(if (orientation >= 5) 2560 else 1920, actual.height)
                    assertTrue("Orientation $orientation pixels", psnr(reference, actual, orientation) > 35)
                    assertTrue(ExifInterface(output.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) in 0..1)
                } finally { actual.recycle() }
            }
        } finally { reference.recycle() }
    }

    @Test fun keepsAlreadyCompressedLargeJpegAndDoesNotRecompressItsOwnOutput() {
        val source = photo(width = 2560, height = 1920, quality = 25, noise = 255)
        assertTrue("Fixture must exceed the compression threshold", source.length() > 512 * 1024)
        assertOriginal(source)
        val first = prepare(photo())
        val second = prepare(first.file)
        assertEquals("Already prepared JPEG must not be degraded again", first.file, second.file)
    }

    @Test fun preservesTextAlphaAnimationHeicRawAndDocumentsByteForByte() {
        val png = image("Screenshot.png", 1440, 3200, Bitmap.CompressFormat.PNG, text = true)
        assertOriginal(png, "image/png")
        val transparent = image("Transparent.png", 1200, 900, Bitmap.CompressFormat.PNG, alpha = true)
        assertOriginal(transparent, "image/png")
        // These fixtures contain real animation/image containers generated with Image I/O.
        for ((name, mime) in listOf("animation.gif" to "image/gif", "animation.png" to "image/png", "photo.heic" to "image/heic")) {
            val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("image-compression/$name").use { it.readBytes() }
            val file = File(root, name).apply { writeBytes(bytes); appendBytes(ByteArray(600 * 1024)) }
            assertOriginal(file, mime)
        }
        for ((name, mime, bytes) in listOf(
            Triple("Raw.dng", "image/x-adobe-dng", "II*RAW".toByteArray()),
            Triple("Document.pdf", "application/pdf", "%PDF-1.4".toByteArray()),
            Triple("Notes.md", "text/markdown", "# Notes".toByteArray()),
            Triple("Audio.m4a", "audio/mp4", "ftypM4A".toByteArray()),
        )) {
            val file = File(root, name).apply { writeBytes(bytes + ByteArray(600 * 1024)) }
            assertOriginal(file, mime)
        }
    }

    @Test fun preservesHdrMultiPictureAndWideGamutJpeg() {
        val source = photo()
        for ((name, marker, payload) in listOf(
            Triple("hdr.jpg", 0xE1, "http://ns.adobe.com/xap/1.0/\u0000hdrgm:Version".toByteArray()),
            Triple("mpo.jpg", 0xE2, "MPF\u0000".toByteArray()),
        )) {
            val file = withSegment(source, name, marker, payload)
            assertOriginal(file)
        }
        val wide = Bitmap.createBitmap(3000, 2000, Bitmap.Config.ARGB_8888, false,
            ColorSpace.get(ColorSpace.Named.DISPLAY_P3))
        val file = File(root, "Wide.jpg")
        try { wide.eraseColor(Color.RED); file.outputStream().use { wide.compress(Bitmap.CompressFormat.JPEG, 100, it) } }
        finally { wide.recycle() }
        // Add harmless padding so the file passes the encoded-size threshold.
        file.appendBytes(ByteArray(600 * 1024))
        assertOriginal(file)
        if (Build.VERSION.SDK_INT >= 34) {
            val hdr = BitmapFactory.decodeFile(source.path)!!
            val gain = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.LTGRAY) }
            val hdrFile = File(root, "UltraHDR.jpg")
            try {
                hdr.gainmap = Gainmap(gain)
                hdrFile.outputStream().use { assertTrue(hdr.compress(Bitmap.CompressFormat.JPEG, 100, it)) }
            } finally { hdr.recycle(); gain.recycle() }
            val decodedHdr = BitmapFactory.decodeFile(hdrFile.path)!!
            try { assertTrue("Fixture must carry a real HDR gain map", decodedHdr.hasGainmap()) }
            finally { decodedHdr.recycle() }
            assertOriginal(hdrFile)
        }
    }

    @Test fun skipsLongScansHugeDimensionsAndLowMemoryBeforeAllocating() {
        assertOriginal(photo(width = 1000, height = 4000))
        val source = photo()
        assertEquals(source, AndroidImageCompression.prepare(source, source.name, "image/jpeg", 1024 * 1024).file)
        val bytes = source.readBytes()
        // Override the JPEG SOF dimensions to exceed 100 megapixels without allocating them.
        var index = 2
        while (index + 9 < bytes.size) {
            val marker = bytes[index + 1].toInt() and 255
            if (marker in listOf(0xC0, 0xC1, 0xC2)) {
                bytes[index + 5] = 0x7f; bytes[index + 6] = 0xff.toByte()
                bytes[index + 7] = 0x7f; bytes[index + 8] = 0xff.toByte()
                break
            }
            index += 2 + ((bytes[index + 2].toInt() and 255) * 256 + (bytes[index + 3].toInt() and 255))
        }
        assertTrue(index + 9 < bytes.size)
        val huge = File(root, "Huge.jpg").apply { writeBytes(bytes) }
        assertOriginal(huge)
        assertFalse(root.listFiles()!!.any { it.name.startsWith(".logseq-compressed-") })
    }

    @Test fun samplesHighResolutionPhotosWithinTheWorkingMemoryBudget() {
        val source = photo(width = 6000, height = 4000)
        val output = AndroidImageCompression.prepare(source, source.name, "image/jpeg", 64L * 1024 * 1024)
        assertNotEquals(source, output.file)
        val (width, height) = dimensions(output.file)
        assertEquals(2560, width)
        assertTrue(height in 1706..1707)
        assertTrue(output.file.length() < source.length() * 9 / 10)
    }

    @Test fun fallsBackWithoutChangingOriginalOnInvalidDataOrOutputFailure() {
        val broken = File(root, "Broken.jpg").apply { writeBytes(byteArrayOf(-1, -40, -1) + ByteArray(600 * 1024)) }
        assertOriginal(broken)
        val source = photo()
        assertTrue(root.setWritable(false))
        try { assertOriginal(source) } finally { root.setWritable(true) }
        assertFalse(root.listFiles()!!.any { it.name.startsWith(".logseq-compressed-") })
    }

    @Test fun correctsMismatchedImageTypesAndFilenames() {
        val source = photo().copyTo(File(root, "Picker.heic"))
        val output = AndroidImageCompression.prepare(source, source.name, "image/heic")
        assertEquals("Picker.jpg", output.title)
        assertEquals("image/jpeg", output.contentType)
        assertEquals("jpg", output.file.extension)
        val png = image("Actual.png", 300, 200, Bitmap.CompressFormat.PNG)
        val mislabelled = png.copyTo(File(root, "Screenshot.jpg"))
        val screenshot = AndroidImageCompression.prepare(mislabelled, mislabelled.name, "image/jpeg")
        assertEquals("Screenshot.png", screenshot.title)
        assertEquals("image/png", screenshot.contentType)
        assertArrayEquals(png.readBytes(), screenshot.file.readBytes())
        assertEquals("image/png", AndroidImageCompression.prepare(png, png.name, "application/octet-stream").contentType)
    }

    @Test fun photoFileCameraAndShareRoutesStoreFinalSizeTypeAndChecksum(): Unit = runBlocking {
        val source = photo()
        val sourceBytes = source.readBytes()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val activity = withContext(Dispatchers.Main) { ImportActivity(context) }
        val importer = AndroidAssetImporter(activity, scope)
        try {
            for (kind in listOf("photos", "files", "camera", "share")) {
                val result = if (kind == "share") importer.importShared(Uri.fromFile(source)) else {
                    activity.request = CompletableDeferred()
                    val pending = scope.async { importer.import(kind) }
                    val (intent, code) = withTimeout(10_000) { activity.request.await() }
                    val data = if (kind == "camera") {
                        val uri = intent.getParcelableExtra<Uri>(MediaStore.EXTRA_OUTPUT)!!
                        context.contentResolver.openOutputStream(uri)!!.use { it.write(sourceBytes) }
                        null
                    } else Intent().setData(Uri.fromFile(source))
                    withContext(Dispatchers.Main) { assertTrue(importer.onActivityResult(code, Activity.RESULT_OK, data)) }
                    withTimeout(20_000) { pending.await() }.single()
                }
                val metadata = requireNotNull(result)
                val stored = File(metadata.getValue("localPath") as String)
                try {
                    assertTrue("$kind must compress photos", stored.length() < source.length() * 9 / 10)
                    assertEquals(stored.length().toInt(), metadata["size"])
                    assertEquals("image/jpeg", metadata["assetType"])
                    assertEquals(sha256(stored.readBytes()), metadata["checksum"])
                    assertEquals(2560 to 1920, dimensions(stored))
                    assertArrayEquals(sourceBytes, source.readBytes())
                } finally { stored.delete() }
            }
            val one = requireNotNull(importer.importShared(Uri.fromFile(source)))
            val two = requireNotNull(importer.importShared(Uri.fromFile(source)))
            assertNotEquals(one["localPath"], two["localPath"])
            File(one["localPath"] as String).delete(); File(two["localPath"] as String).delete()
        } finally { scope.cancel() }
    }

    private class ImportActivity(context: Context) : Activity() {
        var request = CompletableDeferred<Pair<Intent, Int>>()
        init { attachBaseContext(context) }
        override fun startActivityForResult(intent: Intent, requestCode: Int) { request.complete(intent to requestCode) }
    }

    @Test fun concurrentSharedImportsKeepDistinctFilesAndAccurateMetadata(): Unit = runBlocking {
        val source = photo()
        val activity = withContext(Dispatchers.Main) { ImportActivity(context) }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val importer = AndroidAssetImporter(activity, scope)
        try {
            val assets = (1..3).map { scope.async { requireNotNull(importer.importShared(Uri.fromFile(source))) } }.awaitAll()
            assertEquals(3, assets.map { it["localPath"] }.distinct().size)
            for (asset in assets) {
                val file = File(asset["localPath"] as String)
                try {
                    assertTrue(file.length() > 0 && file.length() <= source.length())
                    assertEquals(file.length().toInt(), asset["size"])
                    assertEquals("image/jpeg", asset["assetType"])
                    assertEquals(sha256(file.readBytes()), asset["checksum"])
                } finally { file.delete() }
            }
        } finally { scope.cancel() }
    }

    private fun prepare(file: File) = AndroidImageCompression.prepare(file, file.name, "image/jpeg")
    private fun assertOriginal(file: File, mime: String = "image/jpeg") {
        val bytes = file.readBytes()
        val output = AndroidImageCompression.prepare(file, file.name, mime)
        assertEquals(file, output.file)
        assertArrayEquals(bytes, output.file.readBytes())
    }
    private fun dimensions(file: File): Pair<Int, Int> = BitmapFactory.Options().run {
        inJustDecodeBounds = true; BitmapFactory.decodeFile(file.path, this); outWidth to outHeight
    }
    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun photo(width: Int = 4032, height: Int = 3024, quality: Int = 100, noise: Int = 15): File {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        var seed = 42
        val row = IntArray(width)
        for (y in 0 until height) {
            for (x in 0 until width) {
                seed = 1664525 * seed + 1013904223
                val n = (seed ushr 24) * noise / 255
                row[x] = Color.rgb((x * 220 / width + n).coerceAtMost(255),
                    (y * 220 / height + n).coerceAtMost(255), ((x + y) * 220 / (width + height) + n).coerceAtMost(255))
            }
            bitmap.setPixels(row, 0, width, 0, y, width, 1)
        }
        val file = File(root, "photo-${System.nanoTime()}.jpg")
        try { file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, quality, it)) } }
        finally { bitmap.recycle() }
        return file
    }
    private fun image(name: String, width: Int, height: Int, format: Bitmap.CompressFormat,
                      alpha: Boolean = false, text: Boolean = false): File {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(if (alpha) Color.TRANSPARENT else Color.WHITE)
        if (text) {
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 20f }
            for (y in 40 until height step 40) canvas.drawText("Logseq 图片压缩 Small text 0123456789", 24f, y.toFloat(), paint)
        }
        return File(root, name).also { file ->
            try { file.outputStream().use { bitmap.compress(format, 90, it) } } finally { bitmap.recycle() }
        }
    }
    private fun withSegment(source: File, name: String, marker: Int, payload: ByteArray): File {
        val bytes = source.readBytes()
        val size = payload.size + 2
        return File(root, name).apply { writeBytes(bytes.copyOfRange(0, 2) +
            byteArrayOf(-1, marker.toByte(), (size shr 8).toByte(), size.toByte()) + payload + bytes.copyOfRange(2, bytes.size)) }
    }
    private fun psnr(reference: Bitmap, actual: Bitmap, orientation: Int): Double {
        var error = 0.0; var count = 0
        val w = reference.width; val h = reference.height
        for (y in 0 until actual.height step 4) for (x in 0 until actual.width step 4) {
            val (sx, sy) = when (orientation) {
                2 -> w - 1 - x to y; 3 -> w - 1 - x to h - 1 - y; 4 -> x to h - 1 - y
                5 -> y to x; 6 -> y to h - 1 - x; 7 -> w - 1 - y to h - 1 - x; 8 -> w - 1 - y to x
                else -> x to y
            }
            val a = reference.getPixel(sx, sy); val b = actual.getPixel(x, y)
            for (shift in intArrayOf(0, 8, 16)) {
                val delta = ((a ushr shift) and 255) - ((b ushr shift) and 255)
                error += delta * delta; count++
            }
        }
        return if (error == 0.0) Double.POSITIVE_INFINITY else 10 * log10(255.0 * 255 / (error / count))
    }
}
