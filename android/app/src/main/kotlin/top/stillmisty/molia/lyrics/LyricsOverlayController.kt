package top.stillmisty.molia.lyrics

import android.content.BroadcastReceiver
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.Point
import android.provider.Settings
import android.view.Gravity
import android.view.WindowInsets
import android.view.WindowManager
import androidx.core.content.ContextCompat
import kotlin.math.max

/**
 * 桌面歌词悬浮窗生命周期：显示 / 更新 / 配置 / 位置持久化 / 息屏冻结。
 *
 * 放在应用上下文即可：进程存活期间窗口不受 Activity 前后台影响。
 *
 * 坐标空间：`TYPE_APPLICATION_OVERLAY` 默认按 system bars / 刘海 insets 收边
 * （fitTypes），`LayoutParams.x` 从安全区左缘起算、`y` 从安全区**底缘**起算
 * （[Gravity.BOTTOM]：正数向上偏移），可用区因此必须按
 * [WindowManager.currentWindowMetrics] 减去同类 insets 计算——用 edge-to-edge
 * Activity 的 `resources.displayMetrics`（≈整屏）会多出状态栏高度，
 * 贴底摆放时窗口被导航栏裁掉。
 *
 * 底缘对齐交给窗口重力（而不是「顶缘 + 布局后减高度」）：窗口高度要等首次
 * 布局才有，靠布局回调补位置会让第一帧先画在下面、下一帧再跳上去（单行歌词
 * 尤其明显）；[Gravity.BOTTOM] 让底缘从第一帧就固定，高度变化由系统向上生长。
 *
 * 位置以比例持久化（[xFraction] 取左缘、[bottomFraction] 取底缘，理由见字段注释）；
 * 宽度 / 可用区变化（旋转、`widthPercent`）仍经 [anchorIntoArea] 重新落位并夹进
 * 可用区；高度变化只需夹取，不需要搬动窗口。
 */
internal class LyricsOverlayController(
    private val context: Context,
    private val onAction: (String) -> Unit,
    private val onScreenState: (Boolean) -> Unit,
) {
    private val windowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private var view: LyricsOverlayView? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var currentConfig: OverlayConfig? = null
    private var receiverRegistered = false
    private var callbacksRegistered = false

    /** 上次落位时的窗口尺寸：布局回调靠它区分「真变了」与「只是被拖动」。 */
    private var anchoredWidth = 0
    private var anchoredHeight = 0

    /** 横向位置：窗口左缘在「可用宽 − 窗口宽」区间内的比例。 */
    private var xFraction = DEFAULT_X

    /**
     * 纵向位置：窗口**底缘**在可用高中的比例。
     *
     * 取底缘而非顶缘：底缘由 [Gravity.BOTTOM] 直接锚定，窗口高度不参与定位；
     * 且歌词是贴底摆的「字幕」，高度变化（翻译行出现 / 行数调整 / 控制条
     * 弹出）时底缘固定、向上生长，不会被推出可用区；顶到屏幕上方则回夹在顶部。
     */
    private var bottomFraction = DEFAULT_Y

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    view?.setFrozen(true)
                    onScreenState(false)
                }
                Intent.ACTION_SCREEN_ON -> {
                    view?.setFrozen(false)
                    onScreenState(true)
                }
            }
        }
    }

    private val configurationCallbacks = object : ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) {
            val current = view ?: return
            // 旋转 / 字号（含系统字体缩放）变化：固定行高按 SP 测量，字号变了
            // 必须重新量行高，否则旧行高会把文本裁掉；重排后再落位，新配置下
            // 的布局回调兜底。
            current.post {
                currentConfig?.let { current.applyConfig(it) }
                anchorIntoArea()
            }
        }

        override fun onLowMemory() {}
    }

    fun canDrawOverlays(): Boolean = Settings.canDrawOverlays(context)

    fun isShown(): Boolean = view != null

    fun show(configMap: Map<*, *>?) {
        val config = OverlayConfig.fromMap(configMap)
        if (view == null) {
            createView(config)
        }
        applyConfig(config)
    }

    fun update(presentationMap: Map<*, *>?) {
        view?.setPresentation(OverlayPresentation.fromMap(presentationMap))
    }

    fun setConfig(configMap: Map<*, *>?) {
        applyConfig(OverlayConfig.fromMap(configMap))
    }

    fun hide() {
        val current = view ?: return
        view = null
        layoutParams = null
        currentConfig = null
        anchoredWidth = 0
        anchoredHeight = 0
        try {
            windowManager.removeView(current)
        } catch (_: Exception) {
        }
        unregisterSideEffects()
    }

    /** 重置位置到默认（屏幕下方居中）并清除持久化。 */
    fun resetPosition() {
        prefs.edit().remove(KEY_X).remove(KEY_Y).apply()
        xFraction = DEFAULT_X
        bottomFraction = DEFAULT_Y
        anchorIntoArea()
    }

    /**
     * 可用区尺寸（窗口坐标系）：显示屏尺寸减 system bars / 刘海 insets。
     *
     * 与 [WindowManager.LayoutParams] 的 fitTypes（非 Activity 窗口默认
     * `systemBars | displayCutout`）保持一致，窗口才不会被系统栏裁切。
     */
    private fun safeSize(): Point {
        val metrics = windowManager.currentWindowMetrics
        val insets = metrics.windowInsets.getInsets(
            WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
        )
        return Point(
            (metrics.bounds.width() - insets.left - insets.right).coerceAtLeast(1),
            (metrics.bounds.height() - insets.top - insets.bottom).coerceAtLeast(1),
        )
    }

    private fun windowWidthFor(widthPercent: Float, areaWidth: Int): Int =
        (areaWidth * widthPercent / 100f).toInt().coerceIn(1, areaWidth)

    private fun createView(config: OverlayConfig) {
        currentConfig = config
        anchoredWidth = 0
        anchoredHeight = 0
        xFraction = prefs.getFloat(KEY_X, DEFAULT_X)
        bottomFraction = prefs.getFloat(KEY_Y, DEFAULT_Y)
        val area = safeSize()
        val width = windowWidthFor(config.widthPercent, area.x)
        val params = WindowManager.LayoutParams(
            width,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            baseFlags(config),
            PixelFormat.TRANSLUCENT,
        ).apply {
            // 底缘锚定：y 是「可用区底缘到窗口底缘」的距离，与窗口高度无关，
            // 首次 addView 的坐标就是最终位置（不需要布局回调再补一次）。
            gravity = Gravity.BOTTOM or Gravity.START
            x = (xFraction * max(0, area.x - width)).toInt()
            y = (area.y - bottomFraction * area.y).toInt()
        }
        layoutParams = params

        val overlayView = LyricsOverlayView(
            context = context,
            windowManager = windowManager,
            layoutParams = params,
            areaSize = ::safeSize,
            onDragFinished = ::onDragFinished,
            onAction = onAction,
        )
        overlayView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            maybeAnchorIntoArea()
        }
        try {
            windowManager.addView(overlayView, params)
        } catch (e: Exception) {
            layoutParams = null
            throw e
        }
        view = overlayView
        registerSideEffects()
    }

    /**
     * 布局回调：只有窗口尺寸真的变了才重新落位。
     *
     * 纯移动（拖动）也会触发布局回调，不设防会把窗口拽回旧位置；
     * 拖动中一律不动。宽度变化要重算 x / 宽度；高度变化在底缘重力下
     * 不需要搬窗口，只是把可能越过顶缘的位置夹回来。
     */
    private fun maybeAnchorIntoArea() {
        val current = view ?: return
        if (current.isDragging) return
        if (current.width == anchoredWidth && current.height == anchoredHeight) return
        anchorIntoArea()
    }

    /**
     * 窗口尺寸 / 可用区变化后的唯一权威落点：重算宽度，按比例摆位，夹进可用区。
     *
     * 宽度 = `widthPercent × 可用宽`，旋转后必须跟着变；左缘 = 比例 × 横向可移动
     * 范围、底缘 = 比例 × 可用高，两端不越界。`y` 在 [Gravity.BOTTOM] 下是距
     * 可用区底缘的偏移：0 = 贴底，上限 = 顶边贴可用区顶部。窗口比可用区还高
     * （极多行 + 大字号）时上限为 0，超出顶部的部分由系统裁切。
     */
    private fun anchorIntoArea() {
        val current = view ?: return
        val params = layoutParams ?: return
        val config = currentConfig ?: return
        if (current.isDragging) return
        val area = safeSize()
        val width = windowWidthFor(config.widthPercent, area.x)
        val maxX = max(0, area.x - width)
        val x = (xFraction * maxX).toInt().coerceIn(0, maxX)
        // 底缘位置换算成「距底缘偏移」后夹取：窗口高度只影响上限，
        // 不参与底缘定位（高度变化时底缘保持不动）。
        val y = (area.y - bottomFraction * area.y).toInt()
            .coerceIn(0, max(0, area.y - current.height))
        anchoredWidth = current.width
        anchoredHeight = current.height
        if (params.width == width && params.x == x && params.y == y) return
        params.width = width
        params.x = x
        params.y = y
        try {
            windowManager.updateViewLayout(current, params)
        } catch (_: Exception) {
        }
    }

    /** 拖动结束：把当前矩形换算成比例并持久化（原生直接保存，不经通道回传）。 */
    private fun onDragFinished() {
        if (view == null) return
        val params = layoutParams ?: return
        val area = safeSize()
        val maxX = max(0, area.x - params.width)
        xFraction = if (maxX == 0) DEFAULT_X else (params.x.toFloat() / maxX).coerceIn(0f, 1f)
        // params.y 是距可用区底缘的偏移，底缘 = 可用高 − y。
        bottomFraction = ((area.y - params.y).toFloat() / area.y).coerceIn(0f, 1f)
        prefs.edit()
            .putFloat(KEY_X, xFraction)
            .putFloat(KEY_Y, bottomFraction)
            .apply()
        // 比例即当前位置：再落一次位把尺寸变化挤出的部分夹回可用区（幂等）。
        anchorIntoArea()
    }

    private fun applyConfig(config: OverlayConfig) {
        val current = view ?: return
        val params = layoutParams ?: return
        currentConfig = config
        val flags = baseFlags(config)
        if (params.flags != flags) {
            params.flags = flags
            try {
                windowManager.updateViewLayout(current, params)
            } catch (_: Exception) {
            }
        }
        // 行视图重建触发布局回调，宽度 / 位置由落位逻辑统一刷新。
        current.applyConfig(config)
        anchorIntoArea()
    }

    private fun baseFlags(config: OverlayConfig): Int {
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
        if (config.lock) {
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }
        return flags
    }

    private fun registerSideEffects() {
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            }
            try {
                // 屏幕状态是系统广播（ACTION_SCREEN_ON/OFF 为 protected）。
                // RECEIVER_NOT_EXPORTED 收不到高权限进程（SystemUI 等）发出的
                // 系统广播：息屏能收到、亮屏收不到时 frozen 永远解不开，悬浮窗
                // 停在息屏前那一行。系统广播用 EXPORTED；其他应用无法伪造
                // protected broadcast，安全性不受影响。
                ContextCompat.registerReceiver(
                    context,
                    screenReceiver,
                    filter,
                    ContextCompat.RECEIVER_EXPORTED,
                )
                receiverRegistered = true
            } catch (_: Exception) {
            }
        }
        if (!callbacksRegistered) {
            try {
                context.registerComponentCallbacks(configurationCallbacks)
                callbacksRegistered = true
            } catch (_: Exception) {
            }
        }
    }

    private fun unregisterSideEffects() {
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(screenReceiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
        if (callbacksRegistered) {
            try {
                context.unregisterComponentCallbacks(configurationCallbacks)
            } catch (_: Exception) {
            }
            callbacksRegistered = false
        }
    }

    companion object {
        private const val PREFS_NAME = "molia_lyrics_overlay"

        /** 见 [xFraction] / [bottomFraction]。 */
        private const val KEY_X = "x_fraction"
        private const val KEY_Y = "bottom_fraction"

        private const val DEFAULT_X = 0.5f

        /** 默认贴屏幕下方（底缘位于可用高 92% 处，约等于常见的字幕高度）。 */
        private const val DEFAULT_Y = 0.92f
    }
}
