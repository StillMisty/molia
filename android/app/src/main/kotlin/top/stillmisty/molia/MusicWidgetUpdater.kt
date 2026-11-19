package top.stillmisty.molia

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context

/**
 * 更新所有 [MusicWidget] 实例的统一入口。
 *
 * 旧 `top.stillmisty.molia/widget` 通道与 Pigeon native interop（issue #78）
 * 共用这一份遍历 / 更新逻辑，避免两套行为漂移。
 */
object MusicWidgetUpdater {
    fun update(
        context: Context,
        songName: String?,
        artistName: String?,
        albumArtUrl: String?,
        isPlaying: Boolean,
    ) {
        val appWidgetManager = AppWidgetManager.getInstance(context)
        val appWidgetIds = appWidgetManager.getAppWidgetIds(
            ComponentName(context, MusicWidget::class.java)
        )
        for (appWidgetId in appWidgetIds) {
            MusicWidget.updateAppWidget(
                context = context,
                appWidgetManager = appWidgetManager,
                appWidgetId = appWidgetId,
                songName = songName,
                artistName = artistName,
                albumArtUrl = albumArtUrl,
                isPlaying = isPlaying,
            )
        }
    }
}
