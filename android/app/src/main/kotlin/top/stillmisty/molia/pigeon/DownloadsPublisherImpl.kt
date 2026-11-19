package top.stillmisty.molia.pigeon

import android.content.Context
import androidx.annotation.Keep
import top.stillmisty.molia.downloads.DownloadsPublisherHost

/**
 * Pigeon channel 模式的 DownloadsPublisher host 实现（issue #80）。
 *
 * 只持有 applicationContext：注册与引擎同生命周期，不能捕获 Activity。
 * MediaStore 逻辑复用 [DownloadsPublisherHost]，与旧
 * `top.stillmisty.molia/downloads` 通道走同一份实现；参数校验与旧通道一致
 * （空 sourcePath / displayName 返回 null，空 uri 返回 false）。
 */
@Keep
class DownloadsPublisherImpl(context: Context) : DownloadsPublisherApi {
    private val host = DownloadsPublisherHost(context)

    override fun publicRoot(): String? = host.publicRoot()

    override fun publish(
        sourcePath: String,
        displayName: String,
        mimeType: String,
        relativeDir: String,
    ): String? {
        if (sourcePath.isEmpty() || displayName.isEmpty()) return null
        return host.publish(sourcePath, displayName, mimeType, relativeDir)
    }

    override fun remove(uri: String): Boolean {
        if (uri.isEmpty()) return false
        return host.remove(uri)
    }
}
