package top.stillmisty.molia.saf

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.io.InputStream
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * SAF bridge：本地曲库的文件夹枚举与只读字节读取。
 *
 * 只用系统 `DocumentsContract` API，不新增依赖：Dart 侧保存 picker 返回的
 * `content://` 树 URI，这里按树授权查询子文档、stat、读取标签头。所有调用
 * 都在后台线程执行；错误映射为 MISSING / PERMISSION_DENIED / UNSUPPORTED，
 * Dart 不需要解析异常文本。
 *
 * 遍历用「begin / next / close」拉取：native 保留目录游标，每次只回一页，
 * 不把整棵树塞进 Dart 内存，也不对每个文件发一次平台调用。
 */
class SafChannelHandler(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val resolver: ContentResolver = context.contentResolver
    private val ioExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val sessions = ConcurrentHashMap<String, ScanSession>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "stat" -> {
                val uri = call.argument<String>("uri")?.let(::parseUri)
                    ?: return result.error("INVALID_ARGUMENT", "uri is required", null)
                ioExecutor.execute {
                    try {
                        result.success(statDocument(uri))
                    } catch (e: Exception) {
                        result.error(errorCode(e), e.message, null)
                    }
                }
            }
            "listTreeBegin" -> {
                val uri = call.argument<String>("uri")?.let(::parseUri)
                    ?: return result.error("INVALID_ARGUMENT", "uri is required", null)
                val maxDepth = (call.argument<Int>("maxDepth") ?: 32).coerceIn(1, 64)
                ioExecutor.execute {
                    try {
                        val treeUri = treeUriOf(uri)
                        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
                        val token = UUID.randomUUID().toString()
                        sessions[token] = ScanSession(requireNotNull(treeUri), rootId, maxDepth)
                        result.success(token)
                    } catch (e: Exception) {
                        result.error(errorCode(e), e.message, null)
                    }
                }
            }
            "listTreeNext" -> {
                val token = call.argument<String>("token")
                val maxEntries = (call.argument<Int>("maxEntries") ?: 100).coerceIn(1, 500)
                val session = token?.let(sessions::get)
                    ?: return result.error("INVALID_ARGUMENT", "unknown scan token", null)
                session.executor.execute {
                    try {
                        result.success(session.nextBatch(resolver, maxEntries))
                    } catch (e: Exception) {
                        result.error(errorCode(e), e.message, null)
                    }
                }
            }
            "listTreeClose" -> {
                val token = call.argument<String>("token")
                if (token != null) sessions.remove(token)?.close()
                result.success(null)
            }
            "readHead" -> {
                val uri = call.argument<String>("uri")?.let(::parseUri)
                    ?: return result.error("INVALID_ARGUMENT", "uri is required", null)
                val length = (call.argument<Int>("length") ?: 0).coerceAtLeast(0)
                ioExecutor.execute {
                    try {
                        result.success(readBytes(uri, 0, length))
                    } catch (e: Exception) {
                        result.error(errorCode(e), e.message, null)
                    }
                }
            }
            "readRange" -> {
                val uri = call.argument<String>("uri")?.let(::parseUri)
                    ?: return result.error("INVALID_ARGUMENT", "uri is required", null)
                val start = (call.argument<Long>("start") ?: 0L).coerceAtLeast(0L)
                val length = (call.argument<Int>("length") ?: 0).coerceAtLeast(0)
                ioExecutor.execute {
                    try {
                        result.success(readBytes(uri, start, length))
                    } catch (e: Exception) {
                        result.error(errorCode(e), e.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        sessions.values.forEach { it.close() }
        sessions.clear()
        ioExecutor.shutdownNow()
    }

    /** 文档 / 树根元数据；不存在（cursor 空）返回 null。 */
    private fun statDocument(uri: Uri): Map<String, Any?>? {
        val documentUri = documentUriOf(uri)
        val cursor = resolver.query(documentUri, PROJECTION, null, null, null)
            ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val mime = it.getString(COLUMN_MIME_INDEX)
            return mapOf(
                "displayName" to (it.getString(COLUMN_NAME_INDEX) ?: ""),
                "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                "size" to (it.getLong(COLUMN_SIZE_INDEX)),
                "mtime" to (it.getLong(COLUMN_MTIME_INDEX)),
                "mime" to (mime ?: ""),
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

        val executor: ExecutorService = Executors.newSingleThreadExecutor()
        private val pending = ArrayDeque<Directory>()
        private var currentDirectory: Directory? = null
        private var currentChildren: List<Child>? = null
        private var currentIndex = 0
        private var done = false

        init {
            pending.addLast(Directory(rootDocumentId, "", 0))
        }

        fun nextBatch(resolver: ContentResolver, maxEntries: Int): Map<String, Any?> {
            val entries = mutableListOf<Map<String, Any?>>()
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
                            mapOf(
                                "skip" to "unreadable",
                                "relativePath" to directory.relativePath,
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
                    entries.add(mapOf("skip" to "hidden", "relativePath" to childRelative))
                    continue
                }
                if (child.isDirectory) {
                    if (directory.depth >= maxDepth) {
                        entries.add(
                            mapOf(
                                "skip" to "depthExceeded",
                                "relativePath" to childRelative,
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
                    mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(
                            treeUri,
                            child.documentId,
                        ).toString(),
                        "name" to child.displayName,
                        "relativePath" to childRelative,
                        "isDirectory" to false,
                        "size" to child.size,
                        "mtime" to child.mtime,
                    )
                )
            }
            return mapOf("entries" to entries, "done" to done)
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

        private fun parseUri(value: String): Uri? =
            runCatching { Uri.parse(value) }.getOrNull()

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

        private fun errorCode(error: Exception): String = when (error) {
            is SecurityException -> "PERMISSION_DENIED"
            is FileNotFoundException -> "MISSING"
            is UnsupportedOperationException -> "UNSUPPORTED"
            is IllegalArgumentException -> "UNSUPPORTED"
            else -> "IO"
        }
    }
}
