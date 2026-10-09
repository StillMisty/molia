package top.stillmisty.molia.lyrics

import android.annotation.SuppressLint
import android.content.Context
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.max

/** 悬浮窗配置快照（由 Dart 侧下发；策略已在 Dart 侧应用）。 */
internal data class OverlayConfig(
    val fontSize: Float = 22f,
    val opacity: Float = 1f,
    val playedColor: Int = 0xFFFFFFFF.toInt(),
    val unplayedColor: Int = 0xB3FFFFFF.toInt(),
    val shadowColor: Int = 0x99000000.toInt(),
    val widthPercent: Float = 100f,
    val singleLine: Boolean = false,
    val maxLines: Int = 3,
    val textAlignX: String = "center",
    val textAlignY: String = "center",
    val lock: Boolean = false,
    val freezeOnScreenOff: Boolean = true,
    val showToggleAnimation: Boolean = true,
    val controls: Map<String, Boolean> = mapOf(
        "playPause" to true,
        "previous" to true,
        "next" to true,
        "translation" to true,
        "lock" to true,
        "close" to true,
    ),
) {
    companion object {
        fun fromMap(map: Map<*, *>?): OverlayConfig {
            if (map == null) return OverlayConfig()
            val controls = mutableMapOf<String, Boolean>()
            val rawControls = map["controls"]
            if (rawControls is Map<*, *>) {
                for (key in listOf("playPause", "previous", "next", "translation", "lock", "close")) {
                    controls[key] = rawControls[key] as? Boolean ?: true
                }
            }
            return OverlayConfig(
                fontSize = (map["fontSize"] as? Number)?.toFloat() ?: 22f,
                opacity = (map["opacity"] as? Number)?.toFloat() ?: 1f,
                playedColor = (map["playedColor"] as? Number)?.toInt() ?: 0xFFFFFFFF.toInt(),
                unplayedColor = (map["unplayedColor"] as? Number)?.toInt() ?: 0xB3FFFFFF.toInt(),
                shadowColor = (map["shadowColor"] as? Number)?.toInt() ?: 0x99000000.toInt(),
                widthPercent = (map["widthPercent"] as? Number)?.toFloat() ?: 100f,
                singleLine = map["singleLine"] as? Boolean ?: false,
                maxLines = (map["maxLines"] as? Number)?.toInt() ?: 3,
                textAlignX = map["textAlignX"] as? String ?: "center",
                textAlignY = map["textAlignY"] as? String ?: "center",
                lock = map["lock"] as? Boolean ?: false,
                freezeOnScreenOff = map["freezeOnScreenOff"] as? Boolean ?: true,
                showToggleAnimation = map["showToggleAnimation"] as? Boolean ?: true,
                controls = controls.ifEmpty {
                    mapOf(
                        "playPause" to true,
                        "previous" to true,
                        "next" to true,
                        "translation" to true,
                        "lock" to true,
                        "close" to true,
                    )
                },
            )
        }
    }
}

/** 一次投送的行数据（Dart 侧策略结果）。 */
internal data class OverlayPresentation(
    val title: String = "",
    val line: String = "",
    val extended: List<String> = emptyList(),
    val upcoming: List<String> = emptyList(),
    val isPlaying: Boolean = false,
    val hasLyrics: Boolean = false,
) {
    companion object {
        fun fromMap(map: Map<*, *>?): OverlayPresentation {
            if (map == null) return OverlayPresentation()
            fun stringsOf(key: String): List<String> =
                (map[key] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
            return OverlayPresentation(
                title = map["title"] as? String ?: "",
                line = map["line"] as? String ?: "",
                extended = stringsOf("extended"),
                upcoming = stringsOf("upcoming"),
                isPlaying = map["isPlaying"] as? Boolean ?: false,
                hasLyrics = map["hasLyrics"] as? Boolean ?: false,
            )
        }
    }
}

/**
 * 桌面歌词悬浮视图：拖动移动、点按呼出控制条、锁定后不可触摸（窗口级）。
 *
 * 文本策略（暂停回退 / 无歌词回退 / 翻译开关）由 Dart 侧决定，这里只渲染。
 */
@SuppressLint("ViewConstructor")
internal class LyricsOverlayView(
    context: Context,
    private val windowManager: WindowManager,
    private val layoutParams: WindowManager.LayoutParams,
    private val onDragFinished: (xf: Float, yf: Float) -> Unit,
    private val onAction: (String) -> Unit,
) : LinearLayout(context) {

    private var config = OverlayConfig()
    private var current: OverlayPresentation = OverlayPresentation()
    private var frozen = false
    private var pending: OverlayPresentation? = null
    private var lastRenderedLine: String? = null
    private var controlsVisible = false

    private val textColumn = LinearLayout(context).apply {
        orientation = VERTICAL
    }
    private val controlBar = LinearLayout(context).apply {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        visibility = GONE
    }

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        val pad = dp(8)
        setPadding(pad, pad / 2, pad, pad / 2)
        addView(textColumn, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(controlBar, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        rebuildControls()
    }

    fun applyConfig(next: OverlayConfig) {
        config = next
        alpha = next.opacity.coerceIn(0.1f, 1f)
        gravity = when (next.textAlignY) {
            "top" -> Gravity.TOP
            "bottom" -> Gravity.BOTTOM
            else -> Gravity.CENTER
        }
        textColumn.gravity = when (next.textAlignX) {
            "left" -> Gravity.START
            "right" -> Gravity.END
            else -> Gravity.CENTER
        }
        rebuildControls()
        render(current, animate = false)
    }

    fun setPresentation(presentation: OverlayPresentation) {
        if (frozen && config.freezeOnScreenOff) {
            pending = presentation
            return
        }
        render(presentation, animate = config.showToggleAnimation && presentation.line != lastRenderedLine)
    }

    /** 息屏冻结：停止重绘并缓存最新数据，亮屏恢复时立即刷新。 */
    fun setFrozen(value: Boolean) {
        if (frozen == value) return
        frozen = value
        if (!value) {
            pending?.let {
                pending = null
                render(it, animate = false)
            }
        }
    }

    private fun render(presentation: OverlayPresentation, animate: Boolean) {
        current = presentation
        lastRenderedLine = presentation.line

        val mainCount = if (config.singleLine) 1 else config.maxLines.coerceAtLeast(1)

        data class Entry(val text: String, val isCurrent: Boolean, val isExtended: Boolean)

        val entries = mutableListOf<Entry>()
        if (presentation.line.isNotEmpty()) {
            entries.add(Entry(presentation.line, true, false))
        }
        for (line in presentation.extended) {
            if (line.isNotEmpty()) entries.add(Entry(line, false, true))
        }
        var mainAdded = if (presentation.line.isNotEmpty()) 1 else 0
        for (line in presentation.upcoming) {
            if (mainAdded >= mainCount) break
            if (line.isNotEmpty()) {
                entries.add(Entry(line, false, false))
                mainAdded++
            }
        }

        textColumn.removeAllViews()
        for (entry in entries) {
            val view = TextView(context).apply {
                text = entry.text
                setTextSize(
                    TypedValue.COMPLEX_UNIT_SP,
                    if (entry.isExtended) config.fontSize * 0.8f else config.fontSize,
                )
                setTextColor(if (entry.isCurrent) config.playedColor else config.unplayedColor)
                setShadowLayer(2f, 0f, 1f, config.shadowColor)
                gravity = textColumn.gravity
                maxLines = 1
                setSingleLine(true)
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
            textColumn.addView(view)
        }

        if (animate && textColumn.childCount > 0) {
            val first = textColumn.getChildAt(0)
            first.alpha = 0f
            first.translationY = dp(8).toFloat()
            first.animate().alpha(1f).translationY(0f).setDuration(140L).start()
        }
    }

    private fun rebuildControls() {
        controlBar.removeAllViews()
        val buttons = listOf(
            Triple("previous", "◀◀", "previous"),
            Triple("playPause", if (current.isPlaying) "▮▮" else "▶", "playPause"),
            Triple("next", "▶▶", "next"),
            Triple("translation", "译", "toggleTranslation"),
            Triple("lock", if (config.lock) "解" else "锁", "lock"),
            Triple("close", "×", "close"),
        )
        var any = false
        for ((key, label, action) in buttons) {
            if (config.controls[key] != true) continue
            any = true
            val button = TextView(context).apply {
                text = label
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTextColor(config.playedColor)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                setOnClickListener { onAction(action) }
            }
            controlBar.addView(button)
        }
        if (!any) controlsVisible = false
        controlBar.visibility = if (controlsVisible) VISIBLE else GONE
    }

    private fun toggleControls() {
        if (config.controls.values.none { it }) return
        controlsVisible = !controlsVisible
        controlBar.visibility = if (controlsVisible) VISIBLE else GONE
    }

    // --- 拖动 / 点按 ---

    private var startX = 0f
    private var startY = 0f
    private var startTouchX = 0
    private var startTouchY = 0
    private var dragging = false

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (config.lock) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                startX = event.rawX
                startY = event.rawY
                startTouchX = layoutParams.x
                startTouchY = layoutParams.y
                dragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - startX
                val dy = event.rawY - startY
                if (!dragging && (abs(dx) > dp(4) || abs(dy) > dp(4))) {
                    dragging = true
                    controlsVisible = false
                    controlBar.visibility = GONE
                }
                if (dragging) {
                    layoutParams.x = startTouchX + dx.toInt()
                    layoutParams.y = startTouchY + dy.toInt()
                    clampToScreen()
                    windowManager.updateViewLayout(this, layoutParams)
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (dragging) {
                    onDragFinished(fractionX(), fractionY())
                } else {
                    toggleControls()
                }
                performClick()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    private fun clampToScreen(): Int {
        val metrics = resources.displayMetrics
        layoutParams.x = layoutParams.x.coerceIn(0, max(0, metrics.widthPixels - layoutParams.width))
        layoutParams.y = layoutParams.y.coerceIn(0, max(0, metrics.heightPixels - height))
        return 0
    }

    fun fractionX(): Float {
        val metrics = resources.displayMetrics
        val available = max(1, metrics.widthPixels - layoutParams.width)
        return (layoutParams.x.toFloat() / available).coerceIn(0f, 1f)
    }

    fun fractionY(): Float {
        val metrics = resources.displayMetrics
        val available = max(1, metrics.heightPixels - max(1, height))
        return (layoutParams.y.toFloat() / available).coerceIn(0f, 1f)
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}
