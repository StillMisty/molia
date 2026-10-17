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
 * （fitTypes），`LayoutParams.x/y` 是「安全区左上角」起的偏移，可用区因此必须
 * 按 [WindowManager.currentWindowMetrics] 减去同类 insets 计算——用 edge-to-edge
 * Activity 的 `resources.displayMetrics`（≈整屏）会多出状态栏高度，
 * 贴底摆放时窗口被导航栏裁掉。
 *
 * 位置以比例持久化（[xFraction] 取左缘、[bottomFraction] 取底缘，理由见字段注释）；
 * 任何会让窗口尺寸或可用区变化的时刻（内容行数、控制条、旋转）都经
 * [anchorIntoArea] 重新落位并夹进可用区。
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
     * 取底缘而非顶缘：窗口高度要等首次布局才有，底缘换算不需要高度；
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
            // 旋转 / 字号变化：先落一次位，新配置下的重新布局再由布局回调兜底。
            current.post { anchorIntoArea() }
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
            gravity = Gravity.TOP or Gravity.START
            x = (xFraction * max(0, area.x - width)).toInt()
            // 高度要等首次布局：先当 0 摆在底缘比例处，布局回调随即按真实高度上移。
            y = (bottomFraction * area.y).toInt()
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
     * 拖动中一律不动，高度变化（翻译行 / 行数 / 控制条）才落位。
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
     * 范围、底缘 = 比例 × 可用高，两端不越界。窗口比可用区还高（极多行 + 大字号）
     * 时只能贴顶，超出部分由系统裁切。
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
        val y = ((bottomFraction * area.y).toInt() - current.height)
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
        val current = view ?: return
        val params = layoutParams ?: return
        val area = safeSize()
        val maxX = max(0, area.x - params.width)
        xFraction = if (maxX == 0) DEFAULT_X else (params.x.toFloat() / maxX).coerceIn(0f, 1f)
        bottomFraction = ((params.y + current.height).toFloat() / area.y).coerceIn(0f, 1f)
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
                ContextCompat.registerReceiver(
                    context,
                    screenReceiver,
                    filter,
                    ContextCompat.RECEIVER_NOT_EXPORTED,
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
