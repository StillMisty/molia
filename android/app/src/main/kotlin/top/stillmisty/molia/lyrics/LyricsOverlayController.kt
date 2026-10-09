package top.stillmisty.molia.lyrics

import android.content.BroadcastReceiver
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import androidx.core.content.ContextCompat
import kotlin.math.max

/**
 * 桌面歌词悬浮窗生命周期：显示 / 更新 / 配置 / 位置持久化 / 息屏冻结。
 *
 * 放置在应用上下文即可：进程存活期间窗口不受 Activity 前后台影响；
 * 位置以屏幕可用空间比例持久化（横竖屏换算后仍在可视范围）。
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
            val view = view ?: return
            val params = layoutParams ?: return
            val config = currentConfig ?: return
            val metrics = context.resources.displayMetrics
            val xf = view.fractionX()
            val yf = view.fractionY()
            params.width = (metrics.widthPixels * config.widthPercent / 100f).toInt()
            params.x = ((metrics.widthPixels - params.width) * xf).toInt()
                .coerceIn(0, max(0, metrics.widthPixels - params.width))
            params.y = (metrics.heightPixels * yf).toInt()
                .coerceIn(0, max(0, metrics.heightPixels - view.height))
            try {
                windowManager.updateViewLayout(view, params)
            } catch (_: Exception) {
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
        try {
            windowManager.removeView(current)
        } catch (_: Exception) {
        }
        unregisterSideEffects()
    }

    /** 重置位置到默认（屏幕下方居中）并清除持久化。 */
    fun resetPosition() {
        prefs.edit().remove(KEY_X).remove(KEY_Y).apply()
        val current = view ?: return
        val params = layoutParams ?: return
        val metrics = context.resources.displayMetrics
        params.x = ((metrics.widthPixels - params.width) * DEFAULT_X).toInt().coerceAtLeast(0)
        params.y = (metrics.heightPixels * DEFAULT_Y).toInt()
        try {
            windowManager.updateViewLayout(current, params)
        } catch (_: Exception) {
        }
    }

    private fun createView(config: OverlayConfig) {
        val metrics = context.resources.displayMetrics
        val width = (metrics.widthPixels * config.widthPercent / 100f).toInt()
        val params = WindowManager.LayoutParams(
            width,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            baseFlags(config),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val xf = prefs.getFloat(KEY_X, DEFAULT_X)
            val yf = prefs.getFloat(KEY_Y, DEFAULT_Y)
            x = ((metrics.widthPixels - width) * xf).toInt().coerceAtLeast(0)
            y = (metrics.heightPixels * yf).toInt().coerceAtLeast(0)
        }
        layoutParams = params

        val overlayView = LyricsOverlayView(
            context,
            windowManager,
            params,
            onDragFinished = { x, y -> persistPosition(x, y) },
            onAction = onAction,
        )
        try {
            windowManager.addView(overlayView, params)
        } catch (e: Exception) {
            layoutParams = null
            throw e
        }
        view = overlayView
        // 首次布局后按真实高度把位置夹进屏幕（默认 0.82 对高视图可能越界）。
        overlayView.post {
            val maxY = max(0, metrics.heightPixels - overlayView.height)
            if (params.y > maxY) {
                params.y = maxY
                try {
                    windowManager.updateViewLayout(overlayView, params)
                } catch (_: Exception) {
                }
            }
        }
        registerSideEffects()
    }

    private fun applyConfig(config: OverlayConfig) {
        val current = view ?: return
        val params = layoutParams ?: return
        currentConfig = config
        val metrics = context.resources.displayMetrics
        params.width = (metrics.widthPixels * config.widthPercent / 100f).toInt()
        params.flags = baseFlags(config)
        params.x = params.x.coerceIn(0, max(0, metrics.widthPixels - params.width))
        params.y = params.y.coerceAtLeast(0)
        try {
            windowManager.updateViewLayout(current, params)
        } catch (_: Exception) {
        }
        current.applyConfig(config)
    }

    private fun baseFlags(config: OverlayConfig): Int {
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
        if (config.lock) {
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }
        return flags
    }

    private fun persistPosition(xf: Float, yf: Float) {
        prefs.edit().putFloat(KEY_X, xf).putFloat(KEY_Y, yf).apply()
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
        private const val KEY_X = "x_fraction"
        private const val KEY_Y = "y_fraction"
        private const val DEFAULT_X = 0.5f
        private const val DEFAULT_Y = 0.82f
    }
}
