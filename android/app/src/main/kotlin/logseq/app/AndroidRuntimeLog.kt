package logseq.app

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

enum class AndroidRuntimeLogLevel(val wireValue: String) {
    DEBUG("DEBUG"),
    INFO("INFO"),
    ERROR("ERROR"),
}

enum class AndroidRuntimeLogSource(val wireValue: String) {
    UI("ui"),
    CORE("core"),
}

data class AndroidRuntimeLogRecord(
    val id: Long,
    val timestampMilliseconds: Long,
    val level: AndroidRuntimeLogLevel,
    val source: AndroidRuntimeLogSource,
    val message: String,
)

class AndroidRuntimeLog(private val capacity: Int = 500, private val onError: ((String) -> Unit)? = null) {
    private val maximumCapacity = capacity.coerceAtLeast(1)
    var lastError: AndroidRuntimeLogRecord? = null
        private set
    private var nextId = 0L
    private val storage = mutableListOf<AndroidRuntimeLogRecord>()

    @Synchronized
    fun append(
        level: AndroidRuntimeLogLevel,
        source: AndroidRuntimeLogSource,
        message: String,
        timestampMilliseconds: Long = System.currentTimeMillis(),
    ) {
        nextId += 1
        storage += AndroidRuntimeLogRecord(
            id = nextId,
            timestampMilliseconds = timestampMilliseconds,
            level = level,
            source = source,
            message = message,
        )
        val overflow = storage.size - maximumCapacity
        if (overflow > 0) storage.subList(0, overflow).clear()
        if (level == AndroidRuntimeLogLevel.ERROR) {
            lastError = storage.last()
            onError?.invoke(message)
        }
    }

    @Synchronized
    fun records(
        source: AndroidRuntimeLogSource? = null,
        errorsOnly: Boolean = false,
        newestFirst: Boolean = false,
    ): List<AndroidRuntimeLogRecord> {
        val filtered = storage.filter { record ->
            (source == null || record.source == source) &&
                (!errorsOnly || record.level == AndroidRuntimeLogLevel.ERROR)
        }
        return if (newestFirst) filtered.asReversed() else filtered
    }

    fun encodedRecords(
        source: AndroidRuntimeLogSource? = null,
        errorsOnly: Boolean = false,
        newestFirst: Boolean = false,
    ): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())
        return records(source, errorsOnly, newestFirst).joinToString(prefix = "[", postfix = "]") {
            encodeRecord(it, formatter)
        }
    }

    @Synchronized
    fun encodedSnapshot(source: AndroidRuntimeLogSource?, errorsOnly: Boolean, newestFirst: Boolean): String {
        val records = encodedRecords(source, errorsOnly, newestFirst)
        val error = lastError?.let { encodeRecord(it, SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())) } ?: "null"
        return "{\"records\":$records,\"lastError\":$error}"
    }

    private fun encodeRecord(record: AndroidRuntimeLogRecord, formatter: SimpleDateFormat): String =
        "{" +
            "\"id\":${jsonString(record.id.toString())}," +
            "\"level\":${jsonString(record.level.wireValue)}," +
            "\"source\":${jsonString(record.source.wireValue)}," +
            "\"timestamp\":${jsonString(formatter.format(Date(record.timestampMilliseconds)))}," +
            "\"message\":${jsonString(record.message)}" +
            "}"

    private fun jsonString(value: String): String = buildString {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                else -> if (character < ' ') {
                    append("\\u%04x".format(character.code))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }
}

object AndroidRuntimeLogs {
    private val errorEvents = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val errors = errorEvents.asSharedFlow()
    val shared = AndroidRuntimeLog(onError = { errorEvents.tryEmit(it) })
}
