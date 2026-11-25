package com.logseq.logseq

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

internal object ProfileAvatarCache {
    private const val byteLimit = 128L * 1024
    private const val entryLimit = 64
    private val lifetime = TimeUnit.HOURS.toMillis(1)
    private const val profileBucketHost = "logseq-user-public-metadata-bucket-prod.s3.amazonaws.com"
    private val regionalProfileBucketHost = Regex(
        "logseq-user-public-metadata-bucket-prod\\.s3\\.[a-z0-9-]+\\.amazonaws\\.com"
    )
    private val hosts = setOf(
        "assets.logseq.com", "assets.logseq.io", "avatars.githubusercontent.com", "lh3.googleusercontent.com",
    )
    private val http = OkHttpClient.Builder().callTimeout(2, TimeUnit.SECONDS).followRedirects(false).build()

    fun isProfileBucketHost(host: String): Boolean {
        val normalized = host.lowercase()
        return normalized == profileBucketHost || regionalProfileBucketHost.matches(normalized)
    }

    fun image(context: Context, rawUrl: String?): Bitmap? {
        val url = supportedUrl(rawUrl) ?: return null
        val file = file(context, url)
        val cached = try {
            if (file.length() in 1..byteLimit) decode(file.readBytes()) else null
        } catch (_: IOException) { null }
        if (cached != null && System.currentTimeMillis() - file.lastModified() < lifetime) return cached
        val bytes = download(url) ?: return cached
        val image = decode(bytes) ?: return cached
        store(context, url.toString(), bytes)
        return image
    }

    fun store(context: Context, rawUrl: String, image: ByteArray) {
        val url = supportedUrl(rawUrl) ?: return
        if (image.isEmpty() || image.size > byteLimit) return
        val file = file(context, url)
        val directory = file.parentFile ?: return
        try {
            directory.mkdirs()
            val temp = File.createTempFile("avatar-", ".tmp", directory)
            try {
                temp.writeBytes(image)
                if (temp.renameTo(file)) {
                    directory.listFiles { candidate -> !candidate.name.endsWith(".tmp") }
                        ?.sortedByDescending { it.lastModified() }?.drop(entryLimit)?.forEach { it.delete() }
                }
            } finally {
                temp.delete()
            }
        } catch (_: IOException) {
            // Cache failures do not prevent the fetched avatar from being displayed.
        }
    }

    private fun supportedUrl(rawUrl: String?): HttpUrl? = rawUrl?.toHttpUrlOrNull()?.takeIf {
        it.isHttps && (it.host in hosts || isProfileBucketHost(it.host)) && it.port == 443 && it.query == null &&
            it.fragment == null && it.username.isEmpty() && it.password.isEmpty()
    }

    private fun file(context: Context, url: HttpUrl): File {
        val key = MessageDigest.getInstance("SHA-256").digest(url.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(File(context.cacheDir, "profile-avatars"), key)
    }

    private fun download(url: HttpUrl): ByteArray? = try {
        http.newCall(Request.Builder().url(url).build()).execute().use { response ->
            val body = response.body ?: return@use null
            if (response.code != 200 || body.contentType()?.type != "image" || body.contentLength() > byteLimit) return@use null
            val source = body.source()
            if (source.request(byteLimit + 1)) return@use null
            source.readByteArray()
        }
    } catch (_: IOException) { null }

    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val size = maxOf(bounds.outWidth, bounds.outHeight)
        if (size <= 0) return null
        val options = BitmapFactory.Options().apply { inSampleSize = Integer.highestOneBit(maxOf(1, size / 128)) }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }
}
