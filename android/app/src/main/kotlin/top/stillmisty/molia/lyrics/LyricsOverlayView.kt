package top.stillmisty.molia.lyrics

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.SystemClock
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.TextUtils
import android.text.style.CharacterStyle
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.DrawableRes
import top.stillmisty.molia.R
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
    val maxLines: Int = 1,
    val textAlignX: String = "center",
    val textAlignY: String = "center",
    val lock: Boolean = false,
    val freezeOnScreenOff: Boolean = true,
    val showToggleAnimation: Boolean = true,
    /** 控制条 pill 容器色（Dart 侧按取色来源解析；含透明度）。 */
    val controlBackground: Int = 0xEE1B1B1F.toInt(),
    /** 控制条图标 / 状态层色。 */
    val controlTint: Int = 0xFFFFFFFF.toInt(),
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
        private val CONTROL_KEYS =
            listOf("playPause", "previous", "next", "translation", "lock", "close")

        fun fromMap(map: Map<*, *>?): OverlayConfig {
            if (map == null) return OverlayConfig()
            val controls = mutableMapOf<String, Boolean>()
            val rawControls = map["controls"]
            if (rawControls is Map<*, *>) {
                for (key in CONTROL_KEYS) {
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
                maxLines = (map["maxLines"] as? Number)?.toInt() ?: 1,
                textAlignX = map["textAlignX"] as? String ?: "center",
                textAlignY = map["textAlignY"] as? String ?: "center",
                lock = map["lock"] as? Boolean ?: false,
                freezeOnScreenOff = map["freezeOnScreenOff"] as? Boolean ?: true,
                showToggleAnimation = map["showToggleAnimation"] as? Boolean ?: true,
                controlBackground = (map["controlBackground"] as? Number)?.toInt()
                    ?: 0xEE1B1B1F.toInt(),
                controlTint = (map["controlTint"] as? Number)?.toInt()
                    ?: 0xFFFFFFFF.toInt(),
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

/** 逐字时间轴里的一个词（绝对毫秒）。 */
internal data class OverlayWord(val text: String, val startMs: Long, val endMs: Long)

/** 一次投送的行数据（Dart 侧策略结果）。 */
internal data class OverlayPresentation(
    val title: String = "",
    val line: String = "",
    val extended: List<String> = emptyList(),
    val upcoming: List<String> = emptyList(),
    val isPlaying: Boolean = false,
    val hasLyrics: Boolean = false,
    /** 本次投送时的有效播放位置（已叠加偏移）。 */
    val positionMs: Long = 0L,
    /** 当前行时间轴（-1 = 未知）：无逐字数据时横向滚动按行进度线性外推。 */
    val lineStartMs: Long = -1L,
    val lineEndMs: Long = -1L,
    /** 当前行的逐字时间轴（null = 无逐字数据，按整行着色）。 */
    val words: List<OverlayWord>? = null,
) {
    companion object {
        fun fromMap(map: Map<*, *>?): OverlayPresentation {
            if (map == null) return OverlayPresentation()
            fun stringsOf(key: String): List<String> =
                (map[key] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
            val words = (map["words"] as? List<*>)?.mapNotNull { item ->
                val word = item as? Map<*, *> ?: return@mapNotNull null
                val text = word["t"] as? String ?: return@mapNotNull null
                OverlayWord(
                    text = text,
                    startMs = (word["s"] as? Number)?.toLong() ?: 0L,
                    endMs = (word["e"] as? Number)?.toLong() ?: 0L,
                )
            }?.takeIf { it.isNotEmpty() }
            return OverlayPresentation(
                title = map["title"] as? String ?: "",
                line = map["line"] as? String ?: "",
                extended = stringsOf("extended"),
                upcoming = stringsOf("upcoming"),
                isPlaying = map["isPlaying"] as? Boolean ?: false,
                hasLyrics = map["hasLyrics"] as? Boolean ?: false,
                positionMs = (map["positionMs"] as? Number)?.toLong() ?: 0L,
                lineStartMs = (map["lineStartMs"] as? Number)?.toLong() ?: -1L,
                lineEndMs = (map["lineEndMs"] as? Number)?.toLong() ?: -1L,
                words = words,
            )
        }
    }
}

/** M3 强调缓动（decelerate 段）与离场缓动（accelerate 段）。 */
private val EASE_DECELERATE = PathInterpolator(0.05f, 0.7f, 0.1f, 1f)
private val EASE_ACCELERATE = PathInterpolator(0.3f, 0f, 0.8f, 0.15f)

/**
 * 当前行视图：逐字渐染 + 跟随进度的横向滚动。
 *
 * - 有逐字时间轴时按词插值 playedColor；无逐字数据时整行 playedColor；
 * - 进度基准来自 Dart 侧下发的位置（跟随播放位置通道，≤4Hz），词内 / 行内
 *   用帧回调线性外推，每次收到新位置就重新对齐（暂停 / seek 直接落位）；
 * - 横向滚动按「已唱边界在整行中的比例」映射到溢出宽度：行首即动、行尾
 *   正好滚到位、速度连续；真实文本宽没有超过视图宽时恒不滚动（不使用
 *   原生 marquee：暂停时滚动随进度一起停住）；
 * - 偏移经 [onGroupOffset] 交给宿主，翻译 / 罗马音与主行作为同一滚动组
 *   同步移动、同步裁切。
 * 颜色用可变 color span 而不是自绘：更新颜色不触发重新排版。
 */
@SuppressLint("ViewConstructor")
internal class CurrentLineView(context: Context) : TextView(context) {

    /** 组滚动回调：主行按进度算出的目标偏移交给宿主统一应用到滚动组。 */
    var onGroupOffset: ((Float) -> Unit)? = null

    private var words: List<OverlayWord> = emptyList()
    private var spans: List<MutableColorSpan> = emptyList()
    private var playedColor = 0xFFFFFFFF.toInt()
    private var unplayedColor = 0xB3FFFFFF.toInt()
    private var lineStartMs = -1L
    private var lineEndMs = -1L
    private var basePositionMs = 0L
    private var baseUptimeMs = 0L
    private var playing = false
    private var tickScheduled = false

    private val tick = Runnable {
        tickScheduled = false
        val estimated = estimateMs()
        applyColors(estimated)
        applyScroll(estimated)
        if (shouldKeepTicking(estimated)) scheduleTick()
    }

    /** 绑定/更新词轴、行时间轴与配色；词轴变化时重建 span。 */
    fun bind(
        words: List<OverlayWord>?,
        playedColor: Int,
        unplayedColor: Int,
        lineStartMs: Long,
        lineEndMs: Long,
    ) {
        this.playedColor = playedColor
        this.unplayedColor = unplayedColor
        this.lineStartMs = lineStartMs
        this.lineEndMs = lineEndMs
        val next = words ?: emptyList()
        if (next != this.words) {
            this.words = next
            rebuildSpans()
        }
        val estimated = estimateMs()
        applyColors(estimated)
        applyScroll(estimated)
    }

    /** 对齐到新的播放位置与播放态（每次收到投送都会调用）。 */
    fun syncPosition(positionMs: Long, isPlaying: Boolean) {
        basePositionMs = positionMs
        baseUptimeMs = SystemClock.elapsedRealtime()
        playing = isPlaying
        val estimated = estimateMs()
        applyColors(estimated)
        applyScroll(estimated)
        if (shouldKeepTicking(estimated)) scheduleTick()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // 首次布局 / 宽度变化后补一次滚动（bind 时布局可能还没完成）。
        post { applyScroll(estimateMs()) }
    }

    private fun estimateMs(): Long {
        if (!playing) return basePositionMs
        val elapsed = SystemClock.elapsedRealtime() - baseUptimeMs
        return basePositionMs + max(0L, elapsed)
    }

    private fun shouldKeepTicking(estimatedMs: Long): Boolean {
        if (!playing) return false
        val end = max(lineEndMs, words.lastOrNull()?.endMs ?: -1L)
        return end > 0 && estimatedMs < end
    }

    private fun rebuildSpans() {
        if (words.isEmpty()) {
            spans = emptyList()
            return
        }
        val builder = SpannableStringBuilder()
        val nextSpans = ArrayList<MutableColorSpan>(words.size)
        for (word in words) {
            val start = builder.length
            builder.append(word.text)
            val span = MutableColorSpan(unplayedColor)
            builder.setSpan(span, start, builder.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            nextSpans.add(span)
        }
        spans = nextSpans
        text = builder
    }

    private fun applyColors(positionMs: Long) {
        if (words.isEmpty() || spans.size != words.size) return
        for (index in words.indices) {
            val word = words[index]
            val progress = when {
                word.endMs <= word.startMs ->
                    if (positionMs >= word.endMs) 1f else 0f
                positionMs >= word.endMs -> 1f
                positionMs <= word.startMs -> 0f
                else -> (positionMs - word.startMs).toFloat() /
                    (word.endMs - word.startMs)
            }
            spans[index].color = blend(unplayedColor, playedColor, progress)
        }
        invalidate()
    }

    private fun applyScroll(estimatedMs: Long) {
        onGroupOffset?.invoke(groupScrollOffset(estimatedMs))
    }

    /**
     * 目标组偏移：真实文本宽超出视图宽时，按「已唱比例」把文本滚到对应
     * 位置——行首即动、行尾正好滚到位；没有超出视图时恒为 0。
     */
    private fun groupScrollOffset(estimatedMs: Long): Float {
        val viewWidth = width.toFloat()
        if (viewWidth <= 0f) return 0f
        val textWidth = measuredTextWidth()
        val overflow = textWidth - viewWidth
        if (overflow <= 0f) return 0f
        return (playedFraction(estimatedMs) * overflow).coerceIn(0f, overflow)
    }

    /** 单行真实文本宽：Layout 的行宽；未布局时退回 Paint 测量。 */
    private fun measuredTextWidth(): Float {
        val current = layout
        if (current != null && current.lineCount > 0) {
            return current.getLineWidth(0)
        }
        val value = text?.toString() ?: return 0f
        return paint.measureText(value)
    }

    /**
     * 已唱比例（0..1）：有逐字词轴时取「已唱边界」在整行中的相对位置；
     * 无词轴时按行时间轴线性外推；两者都没有时为 0。
     */
    private fun playedFraction(estimatedMs: Long): Float {
        if (words.isEmpty()) {
            if (lineStartMs < 0 || lineEndMs <= lineStartMs) return 0f
            return ((estimatedMs - lineStartMs).toFloat() / (lineEndMs - lineStartMs))
                .coerceIn(0f, 1f)
        }
        val current = layout ?: return 0f
        val textLength = text?.length ?: 0
        if (textLength <= 0) return 0f
        val startX = current.getPrimaryHorizontal(0)
        val endX = current.getPrimaryHorizontal(textLength)
        val span = endX - startX
        if (span <= 0f) return 0f
        val edgeX = playedEdgeX(current, textLength, estimatedMs)
        return ((edgeX - startX) / span).coerceIn(0f, 1f)
    }

    /** 已唱边界在 Layout 坐标系中的 x（逐字词轴，词内线性插值）。 */
    private fun playedEdgeX(layout: Layout, textLength: Int, estimatedMs: Long): Float {
        var index = words.size
        var fraction = 0f
        for (i in words.indices) {
            val word = words[i]
            if (estimatedMs >= word.endMs) continue
            index = i
            fraction = if (estimatedMs <= word.startMs || word.endMs <= word.startMs) {
                0f
            } else {
                (estimatedMs - word.startMs).toFloat() / (word.endMs - word.startMs)
            }
            break
        }
        if (index >= words.size) return layout.getPrimaryHorizontal(textLength)
        var charStart = 0
        for (i in 0 until index) charStart += words[i].text.length
        val charEnd = (charStart + words[index].text.length).coerceAtMost(textLength)
        val startX = layout.getPrimaryHorizontal(charStart.coerceAtMost(textLength))
        val endX = layout.getPrimaryHorizontal(charEnd)
        return startX + (endX - startX) * fraction
    }

    private fun scheduleTick() {
        if (!tickScheduled) {
            tickScheduled = true
            postOnAnimation(tick)
        }
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        tickScheduled = false
        super.onDetachedFromWindow()
    }

    /** 可变前景色 span：只改颜色不触发排版。 */
    private class MutableColorSpan(var color: Int) : CharacterStyle() {
        override fun updateDrawState(tp: TextPaint) {
            tp.color = color
        }
    }

    private companion object {
        fun blend(from: Int, to: Int, fraction: Float): Int {
            val f = fraction.coerceIn(0f, 1f)
            val a = (Color.alpha(from) + (Color.alpha(to) - Color.alpha(from)) * f).toInt()
            val r = (Color.red(from) + (Color.red(to) - Color.red(from)) * f).toInt()
            val g = (Color.green(from) + (Color.green(to) - Color.green(from)) * f).toInt()
            val b = (Color.blue(from) + (Color.blue(to) - Color.blue(from)) * f).toInt()
            return Color.argb(a, r, g, b)
        }
    }
}

/**
 * 桌面歌词悬浮视图：拖动移动、点按呼出控制条、锁定后不可触摸（窗口级）。
 *
 * - 文本策略（暂停回退 / 无歌词回退 / 行数 / 翻译开关）由 Dart 侧决定；
 * - 当前行用 [CurrentLineView]（逐字渐染 + 跟随进度滚动），翻译 / 罗马音
 *   与之同组同步滚动；其余行整行着色、超宽省略；
 * - 行内容变化做「整块滚入滚出」过渡（旧块上移滚出、新块自下滚入）；
 * - 同结构更新（逐字进度 / 播放态）不重建视图，不打断滚动与动画；
 * - 控制条是 M3E 观感的 pill（圆角容器 + 图标按钮 + 状态层），
 *   颜色由 Dart 侧解析后下发。
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
    private var renderedTexts: List<String> = emptyList()
    private var entryViews = mutableListOf<TextView>()
    private var currentLineView: CurrentLineView? = null
    private var playPauseButton: ImageView? = null
    private var lastIsPlaying = false
    private var controlsVisible = false

    /** 行内对齐（配置的横向对齐）；行自建后各自应用。 */
    private var rowGravity = Gravity.START

    /** 当前行的滚动组：主行 + 翻译 / 罗马音（宿主统一应用组偏移）。 */
    private var scrollGroup = mutableListOf<TextView>()

    /**
     * 裁剪视口：内容列在其中做「滚入滚出」过渡，超出部分裁掉。
     *
     * 过渡期间视口高度固定为新内容高度（窗口高度不抖）；平时回
     * WRAP_CONTENT 跟随内容。
     */
    private val contentHolder = FrameLayout(context).apply {
        clipChildren = true
        clipToPadding = false
    }
    private var textColumn = LinearLayout(context).apply {
        orientation = VERTICAL
    }
    private val controlBar = LinearLayout(context).apply {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        visibility = GONE
    }

    /** 渲染中的一行（主行 / 扩展行 / 后续行）。 */
    private data class Entry(
        val text: String,
        val isCurrent: Boolean,
        val isExtended: Boolean,
        val words: List<OverlayWord>?,
    )

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        val pad = dp(8)
        setPadding(pad, pad / 2, pad, pad / 2)
        contentHolder.addView(
            textColumn,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        addView(contentHolder, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        // 控制条 pill 包裹内容并居中（宽度随按钮数量，不拉满窗口宽度）。
        addView(controlBar, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        rebuildControls()
    }

    fun applyConfig(next: OverlayConfig) {
        config = next
        alpha = next.opacity.coerceIn(0.1f, 1f)
        // 纵向按配置对齐；横向恒居中（控制条 pill 包裹内容，不拉满宽度）。
        gravity = when (next.textAlignY) {
            "top" -> Gravity.TOP
            "bottom" -> Gravity.BOTTOM
            else -> Gravity.CENTER
        } or Gravity.CENTER_HORIZONTAL
        rowGravity = when (next.textAlignX) {
            "left" -> Gravity.START
            "right" -> Gravity.END
            else -> Gravity.CENTER
        }
        rebuildControls()
        render(current, animate = false, force = true)
    }

    fun setPresentation(presentation: OverlayPresentation) {
        if (frozen && config.freezeOnScreenOff) {
            pending = presentation
            return
        }
        render(presentation, animate = config.showToggleAnimation, force = false)
    }

    /** 息屏冻结：停止重绘并缓存最新数据，亮屏恢复时立即刷新。 */
    fun setFrozen(value: Boolean) {
        if (frozen == value) return
        frozen = value
        if (!value) {
            pending?.let {
                pending = null
                render(it, animate = false, force = true)
            }
        }
    }

    // --- 行渲染 ---

    private fun render(presentation: OverlayPresentation, animate: Boolean, force: Boolean) {
        current = presentation
        val entries = buildEntries(presentation)
        val texts = entries.map { it.text }
        val structureSame = !force &&
            texts == renderedTexts &&
            textColumn.childCount == texts.size
        if (structureSame) {
            // 仅进度 / 播放态变化：更新视图内状态，不重建（不打断滚动与动画）。
            currentLineView?.let { line ->
                line.bind(
                    presentation.words,
                    config.playedColor,
                    config.unplayedColor,
                    presentation.lineStartMs,
                    presentation.lineEndMs,
                )
                line.syncPosition(presentation.positionMs, presentation.isPlaying)
            }
            updatePlayPauseIconIfNeeded()
            return
        }
        renderedTexts = texts
        rebuildLineViews(entries, animate)
        updatePlayPauseIconIfNeeded()
    }

    private fun buildEntries(presentation: OverlayPresentation): List<Entry> {
        val mainCount = config.maxLines.coerceAtLeast(1)
        val entries = mutableListOf<Entry>()
        if (presentation.line.isNotEmpty()) {
            entries.add(Entry(presentation.line, true, false, presentation.words))
        }
        for (line in presentation.extended) {
            if (line.isNotEmpty()) entries.add(Entry(line, false, true, null))
        }
        var mainAdded = if (presentation.line.isNotEmpty()) 1 else 0
        for (line in presentation.upcoming) {
            if (mainAdded >= mainCount) break
            if (line.isNotEmpty()) {
                entries.add(Entry(line, false, false, null))
                mainAdded++
            }
        }
        return entries
    }

    /** 构建内容列：当前行挂滚动回调、扩展行并入滚动组；行宽撑满窗口。 */
    private fun buildColumn(entries: List<Entry>): LinearLayout {
        val column = LinearLayout(context).apply { orientation = VERTICAL }
        entryViews = mutableListOf()
        currentLineView = null
        scrollGroup = mutableListOf()
        for (entry in entries) {
            val view: TextView =
                if (entry.isCurrent) {
                    CurrentLineView(context).also {
                        it.onGroupOffset = ::applyGroupScroll
                        currentLineView = it
                    }
                } else {
                    TextView(context)
                }
            view.apply {
                text = entry.text
                setTextSize(
                    TypedValue.COMPLEX_UNIT_SP,
                    if (entry.isExtended) config.fontSize * 0.8f else config.fontSize,
                )
                setTextColor(if (entry.isCurrent) config.playedColor else config.unplayedColor)
                setShadowLayer(2f, 0f, 1f, config.shadowColor)
                gravity = rowGravity
                maxLines = 1
                setSingleLine(true)
                isSelected = false
                isFocusable = false
                isFocusableInTouchMode = false
                if (entry.isCurrent || entry.isExtended) {
                    // 滚动组不做省略号截断：超宽部分随组偏移进出窗口。
                    ellipsize = null
                } else {
                    // 非当前行不做无限循环滚动：超宽截断省略。
                    ellipsize = TextUtils.TruncateAt.END
                }
            }
            column.addView(
                view,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            entryViews.add(view)
            if (entry.isCurrent || entry.isExtended) scrollGroup.add(view)
        }
        return column
    }

    /**
     * 行内容重建：动画关闭（或首次内容）直切；开启时「整块滚入滚出」——
     * 旧块上移滚出、新块自下滚入，视口高度按新内容固定，窗口高度不抖。
     */
    private fun rebuildLineViews(entries: List<Entry>, animate: Boolean) {
        finishPendingRoll()
        val previousColumn = textColumn
        val newColumn = buildColumn(entries)
        val holderParams = contentHolder.layoutParams as? LinearLayout.LayoutParams

        if (!animate || previousColumn.childCount == 0 || contentHolder.width <= 0) {
            holderParams?.height = LinearLayout.LayoutParams.WRAP_CONTENT
            contentHolder.removeAllViews()
            contentHolder.addView(
                newColumn,
                FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
            )
            textColumn = newColumn
            currentLineView?.let { bindCurrentLine(it) }
            return
        }

        val oldHeight = previousColumn.height
        val newHeight = measureColumnHeight(newColumn)
        // 过渡期间视口固定为新内容高度：旧块高出部分裁掉，窗口高度不抖。
        holderParams?.height = newHeight
        newColumn.translationY = newHeight.toFloat()
        newColumn.alpha = 0f
        contentHolder.removeView(previousColumn)
        contentHolder.addView(
            newColumn,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        // 旧块留在视口里做滚出（结束动作里移除；被新块盖住也无妨）。
        contentHolder.addView(
            previousColumn,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        textColumn = newColumn
        currentLineView?.let { bindCurrentLine(it) }

        previousColumn.animate()
            .translationY(-oldHeight.toFloat())
            .alpha(0f)
            .setDuration(ROLL_DURATION_MS)
            .setInterpolator(EASE_DECELERATE)
            .withEndAction {
                if (previousColumn.parent === contentHolder) {
                    contentHolder.removeView(previousColumn)
                }
            }
            .start()
        newColumn.animate()
            .translationY(0f)
            .alpha(1f)
            .setDuration(ROLL_DURATION_MS)
            .setInterpolator(EASE_DECELERATE)
            .start()
    }

    /** 结束未完成的滚入滚出：旧块直接移除、视口回到跟随内容。 */
    private fun finishPendingRoll() {
        for (i in contentHolder.childCount - 1 downTo 0) {
            val child = contentHolder.getChildAt(i)
            if (child !== textColumn) {
                child.animate().cancel()
                contentHolder.removeViewAt(i)
            }
        }
        textColumn.animate().cancel()
        textColumn.translationY = 0f
        textColumn.alpha = 1f
        (contentHolder.layoutParams as? LinearLayout.LayoutParams)?.height =
            LinearLayout.LayoutParams.WRAP_CONTENT
    }

    private fun bindCurrentLine(line: CurrentLineView) {
        line.bind(
            current.words,
            config.playedColor,
            config.unplayedColor,
            current.lineStartMs,
            current.lineEndMs,
        )
        line.syncPosition(current.positionMs, current.isPlaying)
    }

    /** 新列在视口宽度下的高度（滚入滚出的视口高度）。 */
    private fun measureColumnHeight(column: LinearLayout): Int {
        val width = if (contentHolder.width > 0) contentHolder.width else textColumn.width
        if (width <= 0) return column.measuredHeight.coerceAtLeast(0)
        column.measure(
            MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
        )
        return column.measuredHeight
    }

    /**
     * 把滚动组按主行算出的目标偏移应用：每行按自身溢出裁剪——翻译 /
     * 罗马音跟主行一起滚、超出窗口的部分一起被裁掉（消失）。
     */
    private fun applyGroupScroll(offset: Float) {
        for (view in scrollGroup) {
            val overflow = textOverflowOf(view)
            val x = offset.coerceIn(0f, overflow).toInt()
            if (view.scrollX != x) view.scrollTo(x, 0)
        }
    }

    /** 行文本超出视图宽的部分（未布局 / 无溢出为 0）。 */
    private fun textOverflowOf(view: TextView): Float {
        val layout = view.layout ?: return 0f
        if (layout.lineCount <= 0 || view.width <= 0) return 0f
        return (layout.getLineWidth(0) - view.width).coerceAtLeast(0f)
    }

    private fun updatePlayPauseIconIfNeeded() {
        if (lastIsPlaying == current.isPlaying) return
        lastIsPlaying = current.isPlaying
        playPauseButton?.setImageResource(
            if (current.isPlaying) R.drawable.ic_lyrics_pause else R.drawable.ic_lyrics_play,
        )
    }

    // --- 控制条（M3E pill） ---

    private fun rebuildControls() {
        controlBar.removeAllViews()
        playPauseButton = null
        controlBar.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(24).toFloat()
            setColor(config.controlBackground)
        }
        controlBar.setPadding(dp(6), dp(4), dp(6), dp(4))

        val buttons = listOf(
            Triple("previous", R.drawable.ic_lyrics_prev, "previous"),
            Triple("playPause", R.drawable.ic_lyrics_play, "playPause"),
            Triple("next", R.drawable.ic_lyrics_next, "next"),
            Triple("translation", R.drawable.ic_lyrics_translate, "toggleTranslation"),
            Triple("lock", R.drawable.ic_lyrics_lock, "lock"),
            Triple("close", R.drawable.ic_lyrics_close, "close"),
        )
        var any = false
        for ((key, iconRes, action) in buttons) {
            if (config.controls[key] != true) continue
            any = true
            val icon = when (key) {
                "playPause" ->
                    if (current.isPlaying) R.drawable.ic_lyrics_pause
                    else R.drawable.ic_lyrics_play
                "lock" ->
                    if (config.lock) R.drawable.ic_lyrics_lock_open
                    else R.drawable.ic_lyrics_lock
                else -> iconRes
            }
            val button = buildControlButton(icon, action)
            if (key == "playPause") playPauseButton = button
            controlBar.addView(button)
        }
        // 锁定态窗口已点击穿透：控制条必须收起，否则既可见又点不动。
        if (config.lock || !any) {
            hideControlsImmediately()
        } else if (controlsVisible) {
            controlBar.visibility = VISIBLE
            controlBar.alpha = 1f
            controlBar.scaleX = 1f
            controlBar.scaleY = 1f
        }
    }

    private fun buildControlButton(@DrawableRes iconRes: Int, action: String): ImageView {
        val size = dp(42)
        val inset = dp(9)
        return ImageView(context).apply {
            setImageResource(iconRes)
            setColorFilter(config.controlTint)
            scaleType = ImageView.ScaleType.FIT_CENTER
            layoutParams = LayoutParams(size, size)
            setPadding(inset, inset, inset, inset)
            background = controlRipple(config.controlTint)
            setOnClickListener { onAction(action) }
        }
    }

    /** 圆形状态层 ripple：12% 图标色（M3 状态层区间）。 */
    private fun controlRipple(tint: Int): RippleDrawable {
        val mask = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.WHITE)
        }
        val rippleColor = (tint and 0x00FFFFFF) or (0x1F shl 24)
        return RippleDrawable(ColorStateList.valueOf(rippleColor), null, mask)
    }

    private fun setControlsVisible(visible: Boolean) {
        controlsVisible = visible
        controlBar.animate().cancel()
        if (visible) {
            controlBar.visibility = VISIBLE
            controlBar.alpha = 0f
            controlBar.scaleX = 0.92f
            controlBar.scaleY = 0.92f
            controlBar.animate().alpha(1f).scaleX(1f).scaleY(1f)
                .setDuration(180)
                .setInterpolator(EASE_DECELERATE)
                .start()
        } else {
            controlBar.animate().alpha(0f).scaleX(0.94f).scaleY(0.94f)
                .setDuration(140)
                .setInterpolator(EASE_ACCELERATE)
                .withEndAction {
                    if (!controlsVisible) controlBar.visibility = GONE
                }
                .start()
        }
    }

    private fun hideControlsImmediately() {
        controlsVisible = false
        controlBar.animate().cancel()
        controlBar.visibility = GONE
        controlBar.alpha = 1f
        controlBar.scaleX = 1f
        controlBar.scaleY = 1f
    }

    private fun toggleControls() {
        if (config.controls.values.none { it }) return
        setControlsVisible(!controlsVisible)
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
                    hideControlsImmediately()
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

    private companion object {
        /** 行内容滚入滚出时长（M3 强调缓动 decelerate 段）。 */
        const val ROLL_DURATION_MS = 240L
    }
}
