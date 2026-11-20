package top.stillmisty.molia.saf

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 旧 `top.stillmisty.molia/saf` MethodChannel（Pigeon 之前的主路径，现为
 * fallback）。
 *
 * issue #85 起 stat / 会话 begin-next-close / readHead / readRange 与错误码
 * 都收敛在 [SafHost]，本类只做 MethodCall → 参数与 wire map 的翻译；Pigeon
 * `SafApiImpl` 与它共用同一个 host 实例。
 */
class SafChannelHandler(
    messenger: BinaryMessenger,
    private val host: SafHost,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, SafHost.CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "stat" -> host.stat(call.argument<String>("uri").orEmpty()) { outcome ->
                settle(outcome, result) { it?.toWireMap() }
            }
            "listTreeBegin" -> {
                val uri = call.argument<String>("uri").orEmpty()
                val maxDepth = call.argument<Int>("maxDepth") ?: 32
                host.listTreeBegin(uri, maxDepth) { outcome ->
                    settle(outcome, result) { it }
                }
            }
            "listTreeNext" -> {
                val token = call.argument<String>("token").orEmpty()
                val maxEntries = call.argument<Int>("maxEntries") ?: 100
                host.listTreeNext(token, maxEntries) { outcome ->
                    settle(outcome, result) { it.toWireMap() }
                }
            }
            "listTreeClose" -> {
                host.listTreeClose(call.argument<String>("token").orEmpty())
                result.success(null)
            }
            "readHead" -> {
                val uri = call.argument<String>("uri").orEmpty()
                val length = call.argument<Int>("length") ?: 0
                host.readHead(uri, length) { outcome ->
                    settle(outcome, result) { it }
                }
            }
            "readRange" -> {
                val uri = call.argument<String>("uri").orEmpty()
                val start = call.argument<Number>("start")?.toLong() ?: 0L
                val length = call.argument<Int>("length") ?: 0
                host.readRange(uri, start, length) { outcome ->
                    settle(outcome, result) { it }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    /** host 回调 → MethodChannel 结果；失败码与 Pigeon 路径完全一致。 */
    private fun <T> settle(
        outcome: Result<T>,
        result: MethodChannel.Result,
        transform: (T) -> Any?,
    ) {
        outcome.fold(
            onSuccess = { result.success(transform(it)) },
            onFailure = { error ->
                val failure = error.asSafFailure()
                result.error(failure.code, failure.message, null)
            },
        )
    }

    private fun SafDocumentData.toWireMap(): Map<String, Any?> = mapOf(
        "displayName" to displayName,
        "isDirectory" to isDirectory,
        "size" to size,
        "mtime" to mtime,
        "mime" to mime,
    )

    private fun SafTreeBatchData.toWireMap(): Map<String, Any?> = mapOf(
        "entries" to entries.map { it.toWireMap() },
        "done" to done,
    )

    private fun SafTreeEntryData.toWireMap(): Map<String, Any?> =
        if (skip != null) {
            mapOf(
                "skip" to skip,
                "relativePath" to relativePath,
            )
        } else {
            mapOf(
                "uri" to uri,
                "name" to name,
                "relativePath" to relativePath,
                "isDirectory" to isDirectory,
                "size" to size,
                "mtime" to mtime,
            )
        }
}
