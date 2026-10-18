package top.stillmisty.molia.lyrics

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Point
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.SystemClock
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.TextUtils
import android.text.style.CharacterStyle
import android.util.Log
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
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** 悬浮窗配置快照（由 Dart 侧下发；策略已在 Dart 侧应用）。 */
internal data class OverlayConfig(
    val fontSize: Float = 22f,
    /**
     * 行文本字体族（「应用字体」；null = 系统默认）。
     *
     * 名字来自 Dart 侧设备字体枚举（Android 即 `fonts.xml` 的 family/alias），
     * 与 `Typeface.create` 的解析口径同源；解析不到时退回系统默认字体。
     */
    val fontFamily: String? = null,
    val opacity: Float = 1f,
    val playedColor: Int = 0xFFFFFFFF.toInt(),
    val unplayedColor: Int = 0xB3FFFFFF.toInt(),
    val shadowColor: Int = 0x99000000.toInt(),
    val widthPercent: Float = 100f,
    val maxLines: Int = 1,
    val textAlignX: String = "center",
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
                fontFamily = (map["fontFamily"] as? String)?.takeIf { it.isNotBlank() },
                opacity = (map["opacity"] as? Number)?.toFloat() ?: 1f,
                playedColor = (map["playedColor"] as? Number)?.toInt() ?: 0xFFFFFFFF.toInt(),
                unplayedColor = (map["unplayedColor"] as? Number)?.toInt() ?: 0xB3FFFFFF.toInt(),
                shadowColor = (map["shadowColor"] as? Number)?.toInt() ?: 0x99000000.toInt(),
                widthPercent = (map["widthPercent"] as? Number)?.toFloat() ?: 100f,
                maxLines = (map["maxLines"] as? Number)?.toInt() ?: 1,
                textAlignX = map["textAlignX"] as? String ?: "center",
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

/**
 * 滚动组行宽：文本宽 + 余量（取整 / 阴影）。
 *
 * 横滚靠 `translationX` 位移整行，行视图必须比文本宽略大，位移后行尾才
 * 不会被行视图自身的边界裁掉；视口裁切由宿主的裁剪盒负责。
 */
private fun scrollingRowWidth(paint: TextPaint, text: String): Int =
    (ceil(paint.measureText(text)).toInt() + SCROLL_ROW_WIDTH_SLACK).coerceAtLeast(1)

/** 滚动组行宽余量（像素）：取整误差 + 阴影扩散。 */
private const val SCROLL_ROW_WIDTH_SLACK = 4

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
    /** [positionMs] 生效的墙上时刻（毫秒；0 = 未知）：延迟补偿用。 */
    val positionAtEpochMs: Long = 0L,
    /** 横向滚动映射：true = 跟随已唱边界（逐字）；false = 按行跨度线性匀速。 */
    val scrollFollowsSinging: Boolean = true,
    /** 横向滚动的线性映射跨度（-1 = 未知）：无逐字数据时是行时间轴，
     *  匀速模式下 Dart 侧已换成「首词开始 → 末词结束」（终点越过切行
     *  时刻时夹到行尾）；跟随演唱模式下作为提前收尾的兜底口径。 */
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
                positionAtEpochMs =
                    (map["positionAtEpochMs"] as? Number)?.toLong() ?: 0L,
                scrollFollowsSinging = map["scrollFollowsSinging"] as? Boolean ?: true,
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
 * 当前行视图：逐字渐染 + 横向滚动目标计算。
 *
 * - 有逐字时间轴时按词插值 playedColor；无逐字数据时整行 playedColor；
 * - 位置时基不在这里：由宿主 [LyricsOverlayView] 持有 [LyricClock]，每帧
 *   把已纠偏的位置传进来（[applyAt]）。切行重建视图不会打断时基；
 * - 横向滚动按「已唱边界在整行中的比例」映射到溢出宽度：行首即动、行尾
 *   正好滚到位；匀速模式改按 [lineStartMs]/[lineEndMs] 线性映射。行时间轴
 *   可用时再取行时间轴进度兜底（提前 [SCROLL_END_LEAD_MS] 收尾），保证
 *   切行前行尾已经完整露出；真实文本宽没有超过视口宽时恒不滚动；
 * - 词边界 x 坐标按 Layout 缓存（每帧只剩一次查询 + 插值），颜色用可变
 *   color span 而不是自绘：更新颜色不触发重新排版。
 */
@SuppressLint("ViewConstructor")
internal class CurrentLineView(context: Context) : TextView(context) {

    /** 尺寸 / Layout 变化回调：宿主据此补一帧（偏移与裁剪都依赖行宽 / 视口宽）。 */
    var onLayoutChanged: (() -> Unit)? = null

    private var words: List<OverlayWord> = emptyList()
    private var spans: List<MutableColorSpan> = emptyList()
    private var playedColor = 0xFFFFFFFF.toInt()
    private var unplayedColor = 0xB3FFFFFF.toInt()
    private var lineStartMs = -1L
    private var lineEndMs = -1L
    private var scrollFollowsSinging = true

    /** 词边界 x 缓存：`words[i]` 起点 + 末尾哨兵，长度 = words.size + 1。 */
    private var wordEdges: FloatArray? = null
    private var wordEdgesLayout: Layout? = null

    /** 绑定/更新词轴、行时间轴与配色；词轴变化时重建 span。 */
    fun bind(
        words: List<OverlayWord>?,
        playedColor: Int,
        unplayedColor: Int,
        lineStartMs: Long,
        lineEndMs: Long,
        scrollFollowsSinging: Boolean,
    ) {
        this.playedColor = playedColor
        this.unplayedColor = unplayedColor
        this.lineStartMs = lineStartMs
        this.lineEndMs = lineEndMs
        this.scrollFollowsSinging = scrollFollowsSinging
        val next = words ?: emptyList()
        if (next != this.words) {
            this.words = next
            rebuildSpans()
        }
    }

    /** 按位置着色，并返回当前帧的滚动目标偏移（像素）。 */
    fun applyAt(positionMs: Long): Float {
        applyColors(positionMs)
        return targetOffset(positionMs)
    }

    /** 该行是否还需要继续逐帧刷新（行内还有随时间变化的内容）。 */
    fun keepTicking(positionMs: Long): Boolean {
        val end = max(lineEndMs, words.lastOrNull()?.endMs ?: -1L)
        if (end <= 0 || positionMs >= end) return false
        // 无逐字数据且文本不超宽时，行内没有任何随时间变化的内容（不排帧）。
        return words.isNotEmpty() || measuredTextWidth() > viewportWidth()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // 首次布局 / 宽度变化后补一帧（bind 时布局可能还没完成）。
        onLayoutChanged?.invoke()
    }

    private fun rebuildSpans() {
        wordEdges = null
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
        syncPreferredWidth()
    }

    /**
     * 行宽贴合文本宽（见 [scrollingRowWidth]）：横滚靠 `translationX` 位移整行，
     * 行视图必须覆盖整段文本，否则位移后行尾会被行视图自身边界裁掉。
     */
    private fun syncPreferredWidth() {
        val lp = layoutParams as? LinearLayout.LayoutParams ?: return
        val desired = scrollingRowWidth(paint, text?.toString().orEmpty())
        if (lp.width != desired) {
            lp.width = desired
            requestLayout()
        }
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

    /**
     * 目标偏移：真实文本宽超出视口宽时，按「已唱比例」把文本滚到对应
     * 位置——行首即动、行尾正好滚到位；没有超出视口时恒为 0。
     */
    private fun targetOffset(positionMs: Long): Float {
        val viewport = viewportWidth()
        if (viewport <= 0f) return 0f
        val textWidth = measuredTextWidth()
        val overflow = textWidth - viewport
        if (overflow <= 0f) return 0f
        return (playedFraction(positionMs) * overflow).coerceIn(0f, overflow)
    }

    /**
     * 滚动视口宽：父级内容列（即裁剪盒内宽）；未挂载时退回自身宽。
     *
     * 不能用自己的 `width`：行视图宽贴合文本宽（见 [syncPreferredWidth]），
     * 用它当视口会让所有行都被判成「不超宽」而不滚动。
     */
    private fun viewportWidth(): Float {
        val parentWidth = (parent as? View)?.width ?: 0
        return (if (parentWidth > 0) parentWidth else width).toFloat()
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
     * 滚动进度（0..1），保证「切行前必滚完」：
     * - 词轴能在行内收尾（末词不晚于切行时刻）时以词轴为准：取「已唱边界」
     *   在整行中的相对位置，位置整体提前 [SCROLL_END_LEAD_MS]——速度节奏仍随
     *   演唱起伏，行尾在切行前留出可读时间；
     * - 词轴越界（末词晚于切行时刻）或没有词轴时，按 [lineStartMs]/[lineEndMs]
     *   线性推进并提前收尾（匀速模式同此口径）；
     * - 两者都缺时为 0，不滚动。
     */
    private fun playedFraction(positionMs: Long): Float {
        if (scrollFollowsSinging && words.isNotEmpty() && wordsEndWithinLine()) {
            sungFraction(positionMs + scrollLeadMs())?.let { return it }
        }
        return pacedFraction(positionMs) ?: 0f
    }

    /** 词轴是否能在行内收尾（行时间轴未知时按可以处理，不做时间轴兜底）。 */
    private fun wordsEndWithinLine(): Boolean =
        lineStartMs < 0 || lineEndMs <= lineStartMs || words.last().endMs <= lineEndMs

    /** 词轴口径的已完成比例；词轴还没布局时返回 null（下一帧再补）。 */
    private fun sungFraction(positionMs: Long): Float? {
        val edges = wordEdgeX() ?: return null
        val span = edges[edges.size - 1] - edges[0]
        if (span <= 0f) return null
        val edgeX = playedEdgeX(edges, positionMs)
        return ((edgeX - edges[0]) / span).coerceIn(0f, 1f)
    }

    /**
     * 行时间轴口径的进度；提前 [scrollLeadMs] 到达 1，保证行尾在切行前可见。
     * 无有效行时间轴时返回 null。
     */
    private fun pacedFraction(positionMs: Long): Float? {
        if (lineStartMs < 0 || lineEndMs <= lineStartMs) return null
        val span = lineEndMs - lineStartMs
        val denominator = max(1L, span - scrollLeadMs())
        return ((positionMs - lineStartMs).toFloat() / denominator)
            .coerceIn(0f, 1f)
    }

    /** 提前收尾量：夹到行长的三分之一内；行时间轴未知时为 0。 */
    private fun scrollLeadMs(): Long {
        if (lineStartMs < 0 || lineEndMs <= lineStartMs) return 0L
        return min(SCROLL_END_LEAD_MS, (lineEndMs - lineStartMs) / 3)
    }

    /** 已唱边界在 Layout 坐标系中的 x（逐字词轴，词内线性插值）。 */
    private fun playedEdgeX(edges: FloatArray, positionMs: Long): Float {
        for (i in words.indices) {
            val word = words[i]
            if (positionMs >= word.endMs) continue
            val fraction = if (positionMs <= word.startMs || word.endMs <= word.startMs) {
                0f
            } else {
                (positionMs - word.startMs).toFloat() / (word.endMs - word.startMs)
            }
            return edges[i] + (edges[i + 1] - edges[i]) * fraction
        }
        return edges[edges.size - 1]
    }

    /**
     * 词边界 x（按 Layout 缓存）：词轴或排版变化才重算，逐帧只做一次查表。
     *
     * 未布局时返回 null（宿主下一帧会再补）；词长拼接与整行文本一致由
     * Dart 侧保证，这里仍夹取到文本长度防御异常数据。
     */
    private fun wordEdgeX(): FloatArray? {
        val current = layout ?: return null
        if (current.lineCount <= 0) return null
        val cached = wordEdges
        if (cached != null && wordEdgesLayout === current && cached.size == words.size + 1) {
            return cached
        }
        val length = text?.length ?: 0
        val edges = FloatArray(words.size + 1)
        var charIndex = 0
        edges[0] = current.getPrimaryHorizontal(0)
        for (i in words.indices) {
            charIndex = (charIndex + words[i].text.length).coerceAtMost(length)
            edges[i + 1] = current.getPrimaryHorizontal(charIndex)
        }
        wordEdges = edges
        wordEdgesLayout = current
        return edges
    }

    /** 可变前景色 span：只改颜色不触发排版。 */
    private class MutableColorSpan(var color: Int) : CharacterStyle() {
        override fun updateDrawState(tp: TextPaint) {
            tp.color = color
        }
    }

    private companion object {
        /** 横向滚动提前收尾量（毫秒）：行时间轴兜底在切行前给行尾留可读时间。 */
        const val SCROLL_END_LEAD_MS = 300L

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
 * - 当前行用 [CurrentLineView]（逐字渐染 + 横向滚动），翻译 / 罗马音与之同组
 *   同步滚动；其余行整行着色、超宽省略；
 * - 位置时基由宿主统一持有（[LyricClock]）：样本只做纠偏（含传输延迟补偿），
 *   逐帧推进 + 位移跟随（[LyricSpring]）在帧循环里完成——切行重建视图不重锚，
 *   暂停 / seek 直接落位；
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
    /** 可用区尺寸（窗口坐标系，见 [LyricsOverlayController.safeSize]）：拖动夹取用。 */
    private val areaSize: () -> Point,
    private val onDragFinished: () -> Unit,
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

    /** 行内对齐（配置的横向对齐）；普通行各自应用。 */
    private var rowGravity = Gravity.START
    /** 配置的横向对齐原始值（滚动组自行实现对齐，见 applyGroupScroll）。 */
    private var rowAlignX = "center"

    /** 当前行的滚动组：主行 + 翻译 / 罗马音（宿主统一应用组偏移）。 */
    private var scrollGroup = mutableListOf<TextView>()

    /**
     * 当前配置解析出的行字体（null = 不覆盖，用系统默认字体）。
     *
     * 只在 [applyConfig] 里随配置解析一次（`Typeface.create` 要查系统字体表），
     * 行视图重建时套用；配置变化走 `render(force = true)` 全量重建，字体随之
     * 生效（含横滚宽度重新测量——字形度量变了）。
     */
    private var lineTypeface: Typeface? = null

    /**
     * 播放位置时钟：宿主持有（不随行视图重建）——切行不打断时基。
     * 每次投送只做一次样本纠偏，逐帧推进在 [frame] 里完成。
     */
    private val clock = LyricClock()

    /** 滚动位移的临界阻尼跟随：目标每帧可动，输出速度连续。 */
    private val spring = LyricSpring()

    private var frameScheduled = false

    private val frame = object : Runnable {
        override fun run() {
            frameScheduled = false
            applyFrame(advance = true)
            if (shouldKeepFrames()) scheduleFrame()
        }
    }

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
        // 根视图高度贴合内容，纵向 gravity 没有可对齐的富余空间；
        // 横向居中只作用于控制条 pill（包裹内容，不拉满窗口宽度）。
        gravity = Gravity.CENTER_HORIZONTAL
        rowGravity = when (next.textAlignX) {
            "left" -> Gravity.START
            "right" -> Gravity.END
            else -> Gravity.CENTER
        }
        rowAlignX = next.textAlignX
        // 字体族随「应用字体」下发：解析失败（名字不在系统字体表里）退回默认
        // 字体（null = 不覆盖）。变化由下面的全量重建生效。
        lineTypeface = next.fontFamily?.let {
            runCatching { Typeface.create(it, Typeface.NORMAL) }.getOrNull()
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
        if (value) {
            // 冻结关（freezeOnScreenOff=false）保持原行为：息屏照常重绘。
            if (config.freezeOnScreenOff) stopFrames()
            return
        }
        val next = pending
        if (next != null) {
            pending = null
            render(next, animate = false, force = true)
            return
        }
        syncClock()
        applyFrame(advance = false)
        if (shouldKeepFrames()) scheduleFrame()
    }

    override fun onDetachedFromWindow() {
        stopFrames()
        super.onDetachedFromWindow()
    }

    // --- 帧循环（时钟推进 + 位移跟随 + 着色） ---

    /** 是否处于冻结态（息屏 + 冻结开）：冻结期间不排帧、不重绘。 */
    private val isFrozen: Boolean
        get() = frozen && config.freezeOnScreenOff

    private fun scheduleFrame() {
        if (frameScheduled || isFrozen) return
        frameScheduled = true
        postOnAnimation(frame)
    }

    private fun stopFrames() {
        removeCallbacks(frame)
        frameScheduled = false
    }

    /**
     * 一帧：推进时钟 → 行视图着色并给出目标偏移 → 弹簧跟随 → 应用组位移。
     *
     * [advance] 为 false 时用当前时钟值直接落位（bind / 尺寸变化 / 暂停），
     * 不做推进也不做过渡——这些时刻本来就不该有惯性。
     */
    private fun applyFrame(advance: Boolean) {
        if (isFrozen) return
        val now = SystemClock.elapsedRealtime()
        val positionMs = if (advance) clock.advance(now) else clock.currentMs
        val line = currentLineView
        if (line == null) {
            spring.snap(0f, now)
            applyGroupScroll(0f)
            return
        }
        val target = line.applyAt(positionMs)
        val offset = if (advance) spring.advance(target, now) else spring.snap(target, now)
        applyGroupScroll(offset)
    }

    /** 还要不要继续排帧：逐字刷新未结束，或位移尚未收敛。 */
    private fun shouldKeepFrames(): Boolean {
        if (isFrozen) return false
        if (!spring.settled) return true
        if (!current.isPlaying) return false
        return currentLineView?.keepTicking(clock.currentMs) ?: false
    }

    /**
     * 把最新投送对齐进时钟：硬同步（首次 / 暂停 / seek 等不连续）由时钟判定，
     * 连续播放只留相位误差交给逐帧纠偏。
     *
     * 诊断：`adb shell setprop log.tag.MoliaLyrics DEBUG` 后，相位误差超过
     * [CLOCK_LOG_ERROR_MS] 或发生硬同步时会打点（默认级别下静默）。
     */
    private fun syncClock() {
        val transit = transitMsOf(current.positionAtEpochMs)
        val snapped = clock.sync(
            sampleMs = current.positionMs,
            transitMs = transit,
            isPlaying = current.isPlaying,
            nowUptimeMs = SystemClock.elapsedRealtime(),
        )
        if ((snapped || abs(clock.lastErrorMs) >= CLOCK_LOG_ERROR_MS) &&
            Log.isLoggable(CLOCK_LOG_TAG, Log.DEBUG)
        ) {
            Log.d(
                CLOCK_LOG_TAG,
                "err=${clock.lastErrorMs}ms transit=${transit}ms snap=$snapped " +
                    "frames=${clock.framesSinceSample} dt=${clock.lastStepMs}ms " +
                    "sample=${current.positionMs} estimated=${clock.currentMs}",
            )
        }
        clock.resetStepStats()
    }

    /**
     * 样本延迟：Dart 侧「该位置生效的墙上时刻」到此刻的毫秒差。
     *
     * 两端同设备壁钟，直接相减即可；夹取上限防御时钟调整 / 异常数据。
     * 补偿后固定延迟不再进入时基，剩下的抖动由 [LyricClock] 低通。
     */
    private fun transitMsOf(positionAtEpochMs: Long): Long {
        if (positionAtEpochMs <= 0L) return 0L
        val transit = System.currentTimeMillis() - positionAtEpochMs
        return transit.coerceIn(0L, MAX_TRANSIT_MS)
    }

    /** 投送到达后的收尾：对齐时钟；该动就排帧，否则落位一次。 */
    private fun afterPresentation() {
        syncClock()
        if (shouldKeepFrames()) {
            scheduleFrame()
        } else {
            applyFrame(advance = false)
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
                    presentation.scrollFollowsSinging,
                )
            }
            updatePlayPauseIconIfNeeded()
            afterPresentation()
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

    /** 构建内容列：当前行挂滚动回调、扩展行并入滚动组；滚动行宽取文本宽，其余撑满窗口。 */
    private fun buildColumn(entries: List<Entry>): LinearLayout {
        val column = LinearLayout(context).apply { orientation = VERTICAL }
        entryViews = mutableListOf()
        currentLineView = null
        scrollGroup = mutableListOf()
        for (entry in entries) {
            val isScrolling = entry.isCurrent || entry.isExtended
            val view: TextView =
                if (entry.isCurrent) {
                    CurrentLineView(context).also {
                        it.onLayoutChanged = ::reapplyGroupScroll
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
                // 字体必须在测量滚动行宽之前套上（字形度量决定文本宽）。
                lineTypeface?.let { setTypeface(it) }
                setTextColor(if (entry.isCurrent) config.playedColor else config.unplayedColor)
                setShadowLayer(2f, 0f, 1f, config.shadowColor)
                // 滚动组（当前行 / 扩展行）强制左对齐：横向滚动布局宽度是超大
                // 哨兵值（实测 1048576），系统「居中/右对齐」会把布局整体滚走
                // （长文本被推出视口、短文本位置也不受控）；对齐由
                // applyGroupScroll 的偏移统一实现。
                gravity = if (isScrolling) Gravity.START else rowGravity
                maxLines = 1
                setSingleLine(true)
                isSelected = false
                isFocusable = false
                isFocusableInTouchMode = false
                if (isScrolling) {
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
                    // 滚动组行宽取文本宽（见 scrollingRowWidth），其余行撑满窗口。
                    if (isScrolling) {
                        scrollingRowWidth(view.paint, entry.text)
                    } else {
                        LinearLayout.LayoutParams.MATCH_PARENT
                    },
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            entryViews.add(view)
            if (isScrolling) scrollGroup.add(view)
        }
        // 整列（含扩展行）布局完成后重排滚动组偏移，见 [reapplyGroupScroll]。
        column.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            reapplyGroupScroll()
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
            current.scrollFollowsSinging,
        )
        // 切行是新内容：时钟继续走（不重锚），位移直接落位不做过渡。
        syncClock()
        applyFrame(advance = false)
        if (shouldKeepFrames()) scheduleFrame()
    }

    /**
     * 重新落位滚动组：行视图 / 整列布局完成后调用。
     *
     * 不能只依赖主行 [CurrentLineView.onLayoutChanged]：一次布局中主行先于
     * 扩展行完成，扩展行的宽度此时还是 0，x 会被算成 0；列级回调在所有
     * 滚动组成员拿到真实宽度后触发，保证同一帧绘制前摆位正确（暂停时没有
     * 后续帧，必须在这里纠正）。
     */
    private fun reapplyGroupScroll() {
        applyFrame(advance = false)
        if (shouldKeepFrames()) scheduleFrame()
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
     * 把滚动组按主行算出的目标偏移应用：
     * - 文本未超宽：按配置在视口内对齐摆位（滚动组强制左对齐，这里用位移实现）；
     * - 文本超宽：左缘起滚，主行偏移由进度驱动，扩展行按自身溢出裁剪——
     *   翻译 / 罗马音跟主行一起滚、超出视口的部分一起被裁掉（消失）。
     *
     * 位移用 `translationX`（float）：慢速行（长行 / 高刷屏）每帧位移常常不足
     * 1px，整像素滚动会退化成台阶。行视图宽度取文本宽（见 [scrollingRowWidth]），
     * 位移不会把行尾裁在行视图自身边界内；浮点位移的裁切由 contentHolder 承担，
     * 与滚动一致。
     *
     * 符号约定（勿对调）：`translationX` 正 = 内容右移——未超宽时按对齐摆位
     * 取正位移（居中 / 右对齐向右摆，左对齐为 0），超宽后由 0 递减到负溢出
     * （文本向左滚，行尾正好滚到位）。
     */
    private fun applyGroupScroll(groupOffset: Float) {
        val viewport = viewportWidth()
        if (viewport <= 0f) return
        for (view in scrollGroup) {
            val textWidth = textWidthOf(view)
            val overflow = (textWidth - viewport).coerceAtLeast(0f)
            val alignedShift = if (overflow > 0f) {
                0f
            } else {
                when (rowAlignX) {
                    "left" -> 0f
                    "right" -> (viewport - textWidth).coerceAtLeast(0f)
                    else -> ((viewport - textWidth) / 2f).coerceAtLeast(0f)
                }
            }
            val scroll = groupOffset.coerceIn(0f, overflow)
            val x = alignedShift - scroll
            if (view.translationX != x) view.translationX = x
        }
    }

    /** 滚动视口宽：裁剪盒（contentHolder）的内宽。 */
    private fun viewportWidth(): Float =
        (if (contentHolder.width > 0) contentHolder.width else width).toFloat()

    /** 行文本实际宽度（未布局为 0）。 */
    private fun textWidthOf(view: TextView): Float {
        val layout = view.layout ?: return 0f
        if (layout.lineCount <= 0) return 0f
        val width = layout.getLineWidth(0)
        return if (width.isFinite()) width else 0f
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

    /** 拖动中：宿主据此暂停按比例落位，否则窗口每帧被拽回原位。 */
    var isDragging = false
        private set

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (config.lock) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                startX = event.rawX
                startY = event.rawY
                startTouchX = layoutParams.x
                startTouchY = layoutParams.y
                isDragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - startX
                val dy = event.rawY - startY
                if (!isDragging && (abs(dx) > dp(4) || abs(dy) > dp(4))) {
                    isDragging = true
                    hideControlsImmediately()
                }
                if (isDragging) {
                    val area = areaSize()
                    layoutParams.x = (startTouchX + dx.toInt())
                        .coerceIn(0, max(0, area.x - width))
                    layoutParams.y = (startTouchY + dy.toInt())
                        .coerceIn(0, max(0, area.y - height))
                    windowManager.updateViewLayout(this, layoutParams)
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (isDragging) {
                    isDragging = false
                    onDragFinished()
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

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private companion object {
        /** 行内容滚入滚出时长（M3 强调缓动 decelerate 段）。 */
        const val ROLL_DURATION_MS = 240L

        /** 样本延迟夹取上限（毫秒）：防御墙上时钟被调整 / 异常数据。 */
        const val MAX_TRANSIT_MS = 1000L

        /** 诊断日志标签（`adb shell setprop log.tag.MoliaLyrics DEBUG` 开启）。 */
        const val CLOCK_LOG_TAG = "MoliaLyrics"

        /** 相位误差超过该值才打诊断日志（避免 4Hz 刷屏）。 */
        const val CLOCK_LOG_ERROR_MS = 60L
    }
}
