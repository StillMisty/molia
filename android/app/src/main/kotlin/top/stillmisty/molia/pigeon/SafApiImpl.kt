package top.stillmisty.molia.pigeon

import androidx.annotation.Keep
import top.stillmisty.molia.saf.SafDocumentData
import top.stillmisty.molia.saf.SafHost
import top.stillmisty.molia.saf.SafTreeBatchData
import top.stillmisty.molia.saf.SafTreeEntryData
import top.stillmisty.molia.saf.asSafFailure

/**
 * SAF 的 Pigeon host（issue #85）。
 *
 * 与旧 `top.stillmisty.molia/saf` MethodChannel 共用同一个 [SafHost]：文件 /
 * ContentResolver I/O 由 host 的 executor 执行，本类只在回调里做 wire 映射与
 * 错误类转换。生成契约是 `@asyncCallback`，平台主线程不会被 SAF I/O 阻塞。
 *
 * `SafFailure` 必须转成生成的 `SafPigeonError`，否则 Pigeon 会把异常类名当
 * error code，Dart 侧无法区分 MISSING / PERMISSION_DENIED。
 */
@Keep
class SafApiImpl(private val host: SafHost) : SafApi {
    override fun stat(uri: String, callback: (Result<SafDocumentMessage?>) -> Unit) {
        host.stat(uri) { outcome ->
            callback(outcome.map { it?.toMessage() }.asPigeon())
        }
    }

    override fun listTreeBegin(uri: String, maxDepth: Long, callback: (Result<String?>) -> Unit) {
        host.listTreeBegin(uri, maxDepth.toInt()) { outcome ->
            callback(outcome.asPigeon())
        }
    }

    override fun listTreeNext(
        token: String,
        maxEntries: Long,
        callback: (Result<SafTreeBatchMessage?>) -> Unit,
    ) {
        host.listTreeNext(token, maxEntries.toInt()) { outcome ->
            callback(outcome.map { it.toMessage() }.asPigeon())
        }
    }

    override fun listTreeClose(token: String, callback: (Result<Unit>) -> Unit) {
        runCatching { host.listTreeClose(token) }.fold(
            onSuccess = { callback(Result.success(Unit)) },
            onFailure = { callback(Result.failure(it.asPigeonError())) },
        )
    }

    override fun readHead(uri: String, length: Long, callback: (Result<ByteArray?>) -> Unit) {
        host.readHead(uri, length.toInt()) { outcome ->
            callback(outcome.asPigeon())
        }
    }

    override fun readRange(
        uri: String,
        start: Long,
        length: Long,
        callback: (Result<ByteArray?>) -> Unit,
    ) {
        host.readRange(uri, start, length.toInt()) { outcome ->
            callback(outcome.asPigeon())
        }
    }

    private fun SafDocumentData.toMessage(): SafDocumentMessage = SafDocumentMessage(
        uri = uri,
        displayName = displayName,
        isDirectory = isDirectory,
        sizeBytes = size,
        mtimeMs = mtime,
    )

    private fun SafTreeBatchData.toMessage(): SafTreeBatchMessage = SafTreeBatchMessage(
        entries = entries.map { it.toMessage() },
        done = done,
    )

    private fun SafTreeEntryData.toMessage(): SafTreeEntryMessage = SafTreeEntryMessage(
        uri = uri ?: "",
        name = name ?: "",
        relativePath = relativePath,
        isDirectory = isDirectory,
        sizeBytes = size,
        mtimeMs = mtime,
        skip = skip,
    )

    private fun Throwable.asPigeonError(): SafPigeonError {
        val failure = asSafFailure()
        return SafPigeonError(failure.code, failure.message, null)
    }

    private fun <T> Result<T>.asPigeon(): Result<T> = fold(
        onSuccess = { Result.success(it) },
        onFailure = { Result.failure(it.asPigeonError()) },
    )
}
