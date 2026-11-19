package top.stillmisty.molia.pigeon

import android.content.Context
import androidx.annotation.Keep
import top.stillmisty.molia.DownloadNotifications

/**
 * Pigeon channel 模式的 DownloadNotifications host 实现（issue #82）。
 *
 * 只持有 applicationContext：注册与引擎同生命周期，不能捕获 Activity。
 * 通知 / 前台服务逻辑复用 [DownloadNotifications]，与旧
 * `top.stillmisty.molia/download_notifications` 通道走同一份实现。
 *
 * Pigeon 的 Dart `int` 在 Kotlin 侧是 `Long`，这里统一 `toInt()`；字段语义与
 * 旧通道一致（null = 不改 / 未知）。原生侧本身 best-effort，不向 Dart 抛异常。
 */
@Keep
class DownloadNotificationsImpl(context: Context) : DownloadNotificationsApi {
    private val appContext = context.applicationContext

    override fun start(request: StartRequest) {
        DownloadNotifications.start(
            context = appContext,
            id = request.id,
            title = request.title,
            subtitle = request.subtitle,
            index = request.index?.toInt(),
            total = request.total?.toInt(),
            progress = request.progress?.toInt(),
            max = request.max?.toInt(),
            channel = request.channel,
        )
    }

    override fun update(request: UpdateRequest) {
        DownloadNotifications.update(
            context = appContext,
            id = request.id,
            title = request.title,
            subtitle = request.subtitle,
            index = request.index?.toInt(),
            total = request.total?.toInt(),
            progress = request.progress?.toInt(),
            max = request.max?.toInt(),
        )
    }

    override fun stop(id: String) {
        DownloadNotifications.stop(appContext, id)
    }
}
