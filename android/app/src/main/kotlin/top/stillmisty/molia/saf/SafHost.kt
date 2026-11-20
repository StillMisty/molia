package top.stillmisty.molia.saf

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.annotation.Keep
import java.io.FileNotFoundException
import java.io.InputStream
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * SAF 的共享实现：本地曲库的文件夹枚举与只读字节读取。
 *
 * 旧 `top.stillmisty.molia/saf` MethodChannel（[SafChannelHandler]）与 Pigeon
 * `SafApiImpl` 共用本类，锁定 stat / begin-next-close / readHead / readRange
 * 与错误码只有一份（issue #85）。只用系统 `DocumentsContract` API，不新增
 * 依赖：Dart 侧保存 picker 返回的 `content://` 树 URI，这里按树授权查询子
 * 文档、stat、读取标签头。
 *
 * 所有文件 / ContentResolver I/O 都在 [ioExecutor] 或会话自己的单线程 executor
 * 上执行；调用线程（平台主线程 / Pigeon 的后台 task queue）只做参数校验与
 * 派发。失败统一映射为 MISSING / PERMISSION_DENIED / UNSUPPORTED / IO，
 * 两个 transport 拿到的错误码一致。
 */
@Keep
class SafHost(context: Context) {
    private val resolver: ContentResolver = context.applicationContext.contentResolver
    private val ioExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val sessions = ConcurrentHashMap<String, ScanSession>()

    /** 文档 / 树根元数据；不存在（cursor 空）返回 null。 */
    fun stat(uri: String, result: (Result<SafDocumentData?>) -> Unit) {
        val parsed = requireUri(uri, result) ?: return
        dispatch(result) { statDocument(parsed, uri.toString()) }
    }

    /** 开始一次树枚举，返回会话 token。 */
    fun listTreeBegin(uri: String, maxDepth: Int, result: (Result<String>) -> Unit) {
        val parsed = requireUri(uri, result) ?: return
        dispatch(result) {
            val treeUri = treeUriOf(parsed)
                ?: throw SafFailure("UNSUPPORTED", "not a tree uri")
            val rootId = DocumentsContract.getTreeDocumentId(treeUri)
            val token = UUID.randomUUID().toString()
            sessions[token] = ScanSession(treeUri, rootId, maxDepth.coerceIn(1, 64))
            token
        }
    }

    /**
     * 拉取下一批条目。
     *
     * 每个会话有自己的单线程 executor：同一 token 的 next 按提交顺序执行，
     * 不会两个批次同时消费同一个目录游标。
     */
    fun listTreeNext(token: String, maxEntries: Int, result: (Result<SafTreeBatchData>) -> Unit) {
        val session = sessions[token]
            ?: return result(
                Result.failure(SafFailure("INVALID_ARGUMENT", "unknown scan token"))
            )
        session.submit(resolver, maxEntries.coerceIn(1, 500), result)
    }

    /** 关闭会话并回收游标（幂等；未知 token 静默忽略）。 */
    fun listTreeClose(token: String) {
        sessions.remove(token)?.close()
    }

    /** 只读文件头（标签解析）；不存在 / 不可读返回 null。 */
    fun readHead(uri: String, length: Int, result: (Result<ByteArray?>) -> Unit) {
        val parsed = requireUri(uri, result) ?: return
        dispatch(result) { readBytes(parsed, 0, length.coerceAtLeast(0)) }
    }

    /** 读取 `[start, start + length)`；越界按实际可读字节返回。 */
    fun readRange(uri: String, start: Long, length: Int, result: (Result<ByteArray?>) -> Unit) {
        val parsed = requireUri(uri, result) ?: return
        dispatch(result) {
            readBytes(parsed, start.coerceAtLeast(0L), length.coerceAtLeast(0))
        }
    }

    /** 引擎销毁：关闭全部会话并停止线程池。 */
    fun dispose() {
        sessions.values.forEach { it.close() }
        sessions.clear()
        ioExecutor.shutdownNow()
    }

    /** 在后台 executor 上执行；已销毁时立即以 IO 失败回调，避免 Dart 挂起。 */
    private fun <T> dispatch(result: (Result<T>) -> Unit, block: () -> T) {
        try {
            ioExecutor.execute {
                result(runCatching(block).mapError())
            }
        } catch (e: RejectedExecutionException) {
            result(Result.failure(SafFailure("IO", "SAF host is disposed", e)))
        }
    }

    private fun <T> requireUri(uri: String, result: (Result<T>) -> Unit): Uri? {
        val parsed = parseUri(uri)
        if (parsed == null) {
            result(Result.failure(SafFailure("INVALID_ARGUMENT", "uri is required")))
        }
        return parsed
    }

    /** 文档 / 树根元数据；不存在（cursor 空）返回 null。 */
    private fun statDocument(uri: Uri, echoUri: String): SafDocumentData? {
        val documentUri = documentUriOf(uri)
        val cursor = resolver.query(documentUri, PROJECTION, null, null, null)
            ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val mime = it.getString(COLUMN_MIME_INDEX)
            return SafDocumentData(
                uri = echoUri,
                displayName = it.getString(COLUMN_NAME_INDEX) ?: "",
                isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
                size = it.getLong(COLUMN_SIZE_INDEX),
                mtime = it.getLong(COLUMN_MTIME_INDEX),
                mime = mime ?: "",
            )
        }
    }

    private fun readBytes(uri: Uri, start: Long, length: Int): ByteArray? {
        if (length <= 0) return ByteArray(0)
        val input = resolver.openInputStream(uri) ?: return null
        input.use {
            if (start > 0) skipFully(it, start)
            val buffer = ByteArray(length)
            var total = 0
            while (total < length) {
                val read = it.read(buffer, total, length - total)
                if (read < 0) break
                total += read
            }
            return buffer.copyOf(total)
        }
    }

    private fun skipFully(input: InputStream, count: Long) {
        var remaining = count
        val scratch = ByteArray(8 * 1024)
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
                continue
            }
            // 部分 provider 的 skip 只退回 0：读掉而不是死循环。
            val read = input.read(scratch, 0, minOf(scratch.size.toLong(), remaining).toInt())
            if (read < 0) return
            remaining -= read
        }
    }

    private class ScanSession(
        val treeUri: Uri,
        rootDocumentId: String,
        val maxDepth: Int,
    ) {
        data class Directory(val documentId: String, val relativePath: String, val depth: Int)

        data class Child(
            val documentId: String,
            val displayName: String,
            val isDirectory: Boolean,
            val size: Long,
            val mtime: Long,
        )

        private val executor: ExecutorService = Executors.newSingleThreadExecutor()
        private val pending = ArrayDeque<Directory>()
        private var currentDirectory: Directory? = null
        private var currentChildren: List<Child>? = null
        private var currentIndex = 0
        private var done = false

        init {
            pending.addLast(Directory(rootDocumentId, "", 0))
        }

        fun submit(
            resolver: ContentResolver,
            maxEntries: Int,
            result: (Result<SafTreeBatchData>) -> Unit,
        ) {
            try {
                executor.execute {
                    result(runCatching { nextBatch(resolver, maxEntries) }.mapError())
                }
            } catch (e: RejectedExecutionException) {
                result(Result.failure(SafFailure("IO", "scan session is closed", e)))
            }
        }

        private fun nextBatch(resolver: ContentResolver, maxEntries: Int): SafTreeBatchData {
            val entries = mutableListOf<SafTreeEntryData>()
            while (entries.size < maxEntries) {
                if (currentChildren == null) {
                    if (pending.isEmpty()) {
                        done = true
                        break
                    }
                    val directory = pending.removeLast()
                    currentDirectory = directory
                    currentChildren = queryChildren(resolver, directory)
                    currentIndex = 0
                    if (currentChildren == null) {
                        entries.add(
                            SafTreeEntryData(
                                uri = null,
                                name = null,
                                relativePath = directory.relativePath,
                                isDirectory = false,
                                size = 0,
                                mtime = 0,
                                skip = "unreadable",
                            )
                        )
                        continue
                    }
                }
                val children = currentChildren ?: continue
                if (currentIndex >= children.size) {
                    currentChildren = null
                    currentDirectory = null
                    continue
                }
                val directory = currentDirectory ?: continue
                val child = children[currentIndex++]
                val childRelative = if (directory.relativePath.isEmpty()) {
                    child.displayName
                } else {
                    "${directory.relativePath}/${child.displayName}"
                }
                if (child.displayName.startsWith(".")) {
                    entries.add(
                        SafTreeEntryData(
                            uri = null,
                            name = null,
                            relativePath = childRelative,
                            isDirectory = false,
                            size = 0,
                            mtime = 0,
                            skip = "hidden",
                        )
                    )
                    continue
                }
                if (child.isDirectory) {
                    if (directory.depth >= maxDepth) {
                        entries.add(
                            SafTreeEntryData(
                                uri = null,
                                name = null,
                                relativePath = childRelative,
                                isDirectory = false,
                                size = 0,
                                mtime = 0,
                                skip = "depthExceeded",
                            )
                        )
                    } else {
                        pending.addLast(
                            Directory(
                                child.documentId,
                                childRelative,
                                directory.depth + 1,
                            )
                        )
                    }
                    continue
                }
                entries.add(
                    SafTreeEntryData(
                        uri = DocumentsContract.buildDocumentUriUsingTree(
                            treeUri,
                            child.documentId,
                        ).toString(),
                        name = child.displayName,
                        relativePath = childRelative,
                        isDirectory = false,
                        size = child.size,
                        mtime = child.mtime,
                        skip = null,
                    )
                )
            }
            return SafTreeBatchData(entries = entries, done = done)
        }

        private fun queryChildren(
            resolver: ContentResolver,
            directory: Directory,
        ): List<Child>? {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                directory.documentId,
            )
            return try {
                val cursor = resolver.query(childrenUri, PROJECTION, null, null, null)
                    ?: return null
                cursor.use {
                    val children = mutableListOf<Child>()
                    while (it.moveToNext()) {
                        val name = it.getString(COLUMN_NAME_INDEX)
                            ?: it.getString(COLUMN_ID_INDEX)?.substringAfterLast('/')
                            ?: continue
                        val mime = it.getString(COLUMN_MIME_INDEX)
                        children.add(
                            Child(
                                documentId = it.getString(COLUMN_ID_INDEX) ?: continue,
                                displayName = name,
                                isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
                                size = it.getLong(COLUMN_SIZE_INDEX),
                                mtime = it.getLong(COLUMN_MTIME_INDEX),
                            )
                        )
                    }
                    // provider 返回顺序不稳定：排序后同一目录的处理顺序确定。
                    children.sortWith(
                        compareBy(String.CASE_INSENSITIVE_ORDER) { it.displayName }
                    )
                    children
                }
            } catch (e: SecurityException) {
                null
            } catch (e: IllegalArgumentException) {
                null
            }
        }

        fun close() {
            done = true
            pending.clear()
            executor.shutdownNow()
        }
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/saf"

        private val PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        private const val COLUMN_ID_INDEX = 0
        private const val COLUMN_NAME_INDEX = 1
        private const val COLUMN_MIME_INDEX = 2
        private const val COLUMN_SIZE_INDEX = 3
        private const val COLUMN_MTIME_INDEX = 4

        private fun parseUri(value: String): Uri? {
            if (value.isEmpty()) return null
            return runCatching { Uri.parse(value) }.getOrNull()
        }

        /**
         * 是否为树根本身（`/tree/<id>`）。
         *
         * 注意 `DocumentsContract.isTreeUri()` 对 `/tree/<id>/document/<doc>` 也
         * 返回 true；这里必须看路径段，否则会把子文档误当成树根。
         */
        private fun isTreeRootUri(uri: Uri): Boolean {
            val segments = uri.pathSegments
            return segments.size == 2 && segments[0] == "tree"
        }

        /** 树 URI 或树内文档 URI → 树 URI。 */
        private fun treeUriOf(uri: Uri): Uri? {
            if (isTreeRootUri(uri)) return uri
            val segments = uri.pathSegments
            val treeIndex = segments.indexOf("tree")
            if (treeIndex < 0 || treeIndex + 1 >= segments.size) return null
            return Uri.Builder()
                .scheme("content")
                .authority(uri.authority)
                .appendPath("tree")
                .appendPath(segments[treeIndex + 1])
                .build()
        }

        private fun documentUriOf(uri: Uri): Uri {
            if (!isTreeRootUri(uri)) return uri
            val documentId = DocumentsContract.getTreeDocumentId(uri)
            return DocumentsContract.buildDocumentUriUsingTree(uri, documentId)
        }
    }
}

/** 结构化 stat 结果；旧通道 map 与 Pigeon 消息都由它映射。 */
@Keep
data class SafDocumentData(
    val uri: String,
    val displayName: String,
    val isDirectory: Boolean,
    val size: Long,
    val mtime: Long,
    val mime: String,
)

/**
 * 树枚举的一条结果。
 *
 * [skip] 非空表示被跳过的目录 / 文件（hidden / depthExceeded / unreadable），
 * 此时 [uri] / [name] 为 null、数值字段为 0；真实文件条目 [skip] 为 null。
 */
@Keep
data class SafTreeEntryData(
    val uri: String?,
    val name: String?,
    val relativePath: String,
    val isDirectory: Boolean,
    val size: Long,
    val mtime: Long,
    val skip: String?,
)

/** 一页树枚举结果；[done] 为 true 表示 native 会话已无更多条目。 */
@Keep
data class SafTreeBatchData(
    val entries: List<SafTreeEntryData>,
    val done: Boolean,
)

/** 稳定失败码（与 Dart `SafFailureKind` 对应；INVALID_ARGUMENT 在 Dart 归 IO）。 */
@Keep
class SafFailure(
    val code: String,
    override val message: String?,
    cause: Throwable? = null,
) : Exception(message, cause)

/** 任意异常 → 稳定错误码；两个 transport 在回调前都经过这里。 */
internal fun Throwable.asSafFailure(): SafFailure = when (this) {
    is SafFailure -> this
    is SecurityException -> SafFailure("PERMISSION_DENIED", message, this)
    is FileNotFoundException -> SafFailure("MISSING", message, this)
    is UnsupportedOperationException -> SafFailure("UNSUPPORTED", message, this)
    is IllegalArgumentException -> SafFailure("UNSUPPORTED", message, this)
    else -> SafFailure("IO", message, this)
}

internal fun <T> Result<T>.mapError(): Result<T> =
    if (isSuccess) this else Result.failure(exceptionOrNull()!!.asSafFailure())
