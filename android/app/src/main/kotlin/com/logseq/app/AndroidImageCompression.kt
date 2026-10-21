package com.logseq.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import java.io.DataInputStream
import java.io.File

internal object AndroidImageCompression {
    data class Prepared(val file: File, val title: String, val contentType: String)

    private val imageTypes = mapOf("jpg" to "image/jpeg", "jpeg" to "image/jpeg",
        "png" to "image/png", "gif" to "image/gif", "webp" to "image/webp")

    // Shared intents launch parallel imports; admit only one bitmap working set.
    @Synchronized fun prepare(
        file: File,
        title: String,
        contentType: String,
        memoryBudgetBytes: Long? = null,
    ): Prepared {
        val original = Prepared(file, title, contentType)
        val extension = File(title).extension.lowercase()
        if (!contentType.startsWith("image/") && extension !in imageTypes) return original
        var fallback = original
        var decoded: Bitmap? = null
        var output: Bitmap? = null
        var candidate: File? = null
        var accepted = false
        try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            val mime = bounds.outMimeType ?: return original
            if (mime !in imageTypes.values) return original
            val correctExtension = if (mime == "image/jpeg") "jpg" else mime.substringAfter('/')
            val correctedTitle = if (imageTypes[extension] == mime) title
                else title.substringBeforeLast('.', title) + "." + correctExtension
            fallback = Prepared(file, correctedTitle, mime)
            // Preserve screenshots, alpha and animation without decoding pixels.
            // HEIC and RAW also bypass encoding, retaining all original image semantics.
            if (mime != "image/jpeg") return fallback
            val width = bounds.outWidth
            val height = bounds.outHeight
            if (file.length() <= 512 * 1024 || width <= 0 || height <= 0 ||
                width.toLong() * height > 100_000_000 || maxOf(width, height).toDouble() / minOf(width, height) > 3 ||
                bounds.outColorSpace?.isSrgb == false || hasAdditionalImages(file)) return fallback

            var sample = 1
            val longest = maxOf(width, height)
            while (longest / (sample * 2) >= 2560) sample *= 2
            val sampledWidth = (width + sample - 1) / sample
            val sampledHeight = (height + sample - 1) / sample
            val scale = minOf(1.0, 2560.0 / maxOf(sampledWidth, sampledHeight))
            val decodedBytes = sampledWidth.toLong() * sampledHeight * 4
            val outputBytes = (sampledWidth * scale).toLong() * (sampledHeight * scale).toLong() * 4
            if (decodedBytes + outputBytes + 8 * 1024 * 1024 > (memoryBudgetBytes ?: availableMemoryBudget())) return fallback

            val orientation = ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)
            if (orientation !in 0..8) return fallback
            decoded = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }) ?: return fallback
            if (decoded.colorSpace?.isSrgb == false || (Build.VERSION.SDK_INT >= 34 && decoded.hasGainmap())) return fallback
            val actualScale = minOf(1f, 2560f / maxOf(decoded.width, decoded.height))
            val transform = orientationTransform(orientation, actualScale)
            output = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, transform, true)
            candidate = File.createTempFile(".logseq-compressed-", ".jpg", file.parentFile)
            val encoded = candidate.outputStream().use { output.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            if (!encoded || candidate.length() == 0L || candidate.length() >= file.length() * 9 / 10) return fallback
            accepted = true
            return Prepared(candidate, correctedTitle, "image/jpeg")
        } catch (_: Exception) {
            return fallback
        } catch (_: OutOfMemoryError) {
            return fallback
        } finally {
            if (output !== decoded) output?.recycle()
            decoded?.recycle()
            if (!accepted) candidate?.delete()
        }
    }

    private fun availableMemoryBudget(): Long = Runtime.getRuntime().run {
        minOf(96L * 1024 * 1024, (maxMemory() - totalMemory() + freeMemory()).coerceAtLeast(0) / 2)
    }

    private fun orientationTransform(orientation: Int, scale: Float): Matrix {
        val values = when (orientation) {
            2 -> floatArrayOf(-1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)
            3 -> floatArrayOf(-1f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 1f)
            4 -> floatArrayOf(1f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 1f)
            5 -> floatArrayOf(0f, 1f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)
            6 -> floatArrayOf(0f, -1f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)
            7 -> floatArrayOf(0f, -1f, 0f, -1f, 0f, 0f, 0f, 0f, 1f)
            8 -> floatArrayOf(0f, 1f, 0f, -1f, 0f, 0f, 0f, 0f, 1f)
            else -> floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)
        }
        for (index in 0..5) values[index] *= scale
        return Matrix().apply { setValues(values) }
    }

    // MPF and XMP can describe Ultra HDR gain maps, depth or multiple photographs.
    // Keep unknown APP1/APP11 metadata intact rather than flattening those semantics.
    private fun hasAdditionalImages(file: File): Boolean = DataInputStream(file.inputStream().buffered()).use { input ->
        if (input.readUnsignedShort() != 0xffd8) return true
        var consumed = 2L
        while (consumed < 4 * 1024 * 1024) {
            if (input.readUnsignedByte() != 0xff) return true
            var marker = input.readUnsignedByte()
            while (marker == 0xff) {
                if (++consumed >= 4 * 1024 * 1024) return true
                marker = input.readUnsignedByte()
            }
            if (marker == 0xda) return false
            if (marker == 0xd9 || marker == 0xeb) return true
            val length = input.readUnsignedShort() - 2
            if (length < 0) return true
            consumed += length + 4
            if (marker == 0xe1 || marker == 0xe2) {
                val payload = ByteArray(length)
                input.readFully(payload)
                if (marker == 0xe1 && !payload.startsWith(byteArrayOf(69, 120, 105, 102, 0, 0))) return true
                if (marker == 0xe2 && payload.startsWith(byteArrayOf(77, 80, 70, 0))) return true
            } else if (input.skipBytes(length) != length) return true
        }
        true
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
        size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}
