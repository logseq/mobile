package logseq.app

import androidx.annotation.Keep

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

// Native JNI calls these entry points by class and method name.
@Keep
object AndroidHttpTransport {
    private const val timeoutMillis = 30_000
    @Volatile private var filesDirectory: File? = null

    @JvmStatic
    fun initialize(context: Context) {
        filesDirectory = context.filesDir
    }

    @JvmStatic
    fun send(method: String, url: String, body: String, token: String): String = runCatching {
        val connection = open(method, url, token)
        if (body.isNotEmpty()) {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        response(connection)
    }.getOrElse {
        android.util.Log.w("AndroidHttpTransport", "send failed\n${it.stackTraceToString()}")
        "ERROR\n${it.message ?: it.javaClass.simpleName}"
    }

    @JvmStatic
    fun uploadFile(
        method: String,
        url: String,
        filePath: String,
        contentType: String,
        token: String,
    ): String = runCatching {
        val supplied = File(filePath)
        val file = if (supplied.isAbsolute) {
            supplied
        } else {
            resolveAndroidFile(
                requireNotNull(filesDirectory) { "Android HTTP transport is not initialized" },
                filePath,
            )
        }
        require(file.isFile) { "Asset file does not exist: $filePath" }
        val connection = open(method, url, token)
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(file.length())
        connection.setRequestProperty("Content-Type", contentType)
        connection.outputStream.use { output ->
            file.inputStream().use { input -> input.copyTo(output) }
        }
        response(connection)
    }.getOrElse {
        android.util.Log.w("AndroidHttpTransport", "upload failed\n${it.stackTraceToString()}")
        "ERROR\n${it.message ?: it.javaClass.simpleName}"
    }

    private fun open(method: String, url: String, token: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 30_000
            readTimeout = timeoutMillis
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/json")
        }

    private fun response(connection: HttpURLConnection): String {
        return try {
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            "$status\n$body"
        } finally {
            connection.disconnect()
        }
    }
}
