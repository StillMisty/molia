package top.stillmisty.molia.pigeon

import android.content.Context
import androidx.annotation.Keep
import top.stillmisty.molia.MusicWidgetUpdater

/**
 * Pigeon native interop 的 widget host 实现（issue #78）。
 *
 * 只持有 applicationContext：注册与引擎同生命周期，不能捕获 Activity。
 * 实际更新复用 [MusicWidgetUpdater]，与旧通道走同一份逻辑。
 */
@Keep
class WidgetApiImpl(context: Context) : WidgetApi {
    private val appContext = context.applicationContext

    override fun update(payload: WidgetPayload) {
        android.util.Log.d("MoliaWidget", "Pigeon WidgetApi.update")
        MusicWidgetUpdater.update(
            context = appContext,
            songName = payload.songName,
            artistName = payload.artistName,
            albumArtUrl = payload.albumArtUrl,
            isPlaying = payload.isPlaying,
        )
    }
}
