package top.stillmisty.molia.lyrics

import android.content.Context

/**
 * 进程级悬浮窗 owner：同一时刻只允许存在一个歌词窗口。
 *
 * 为什么需要它：`TYPE_APPLICATION_OVERLAY` 的窗口挂在进程级
 * `WindowManagerGlobal` 上，Activity / FlutterEngine 销毁不会自动移除。
 * 如果每个 [LyricsChannelHandler] 各自持有一个 controller，引擎重建后
 * 旧窗口会停在旧歌词上，新引擎再建一个窗口——表现为「上一句还在，
 * 下一句叠在上面跟着进度走」（两个窗口同位置重叠）。
 *
 * 新引擎 acquire 时先销毁旧 controller；旧引擎随后 release 时只销毁
 * 自己持有的那个，不会误伤新窗口。
 */
internal object LyricsOverlayHost {
    private var active: LyricsOverlayController? = null

    fun acquire(
        context: Context,
        onAction: (String) -> Unit,
        onScreenState: (Boolean) -> Unit,
    ): LyricsOverlayController {
        active?.dispose()
        val controller = LyricsOverlayController(
            context = context.applicationContext ?: context,
            onAction = onAction,
            onScreenState = onScreenState,
        )
        active = controller
        return controller
    }

    fun release(controller: LyricsOverlayController) {
        if (active !== controller) return
        active = null
        controller.dispose()
    }
}
