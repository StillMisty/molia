package top.stillmisty.molia.lyrics

import kotlin.math.abs
import kotlin.math.exp

/**
 * 逐字歌词的播放位置时钟：本地按帧推进 + 相位纠偏（PLL / 时钟 slew）。
 *
 * 为什么不是「每次收到位置就重设基准」：位置样本经 Dart（≤4Hz）→ 通道 →
 * 原生主线程到达，投递延迟随宿主负载波动；把到达时刻当基准会把这段抖动
 * 1:1 转成可见的回跳（忽快忽慢）。这里让本地时钟连续推进，样本只用于纠偏：
 *
 * - `|误差| > [hardSnapMs]`（seek / 恢复播放 / 换曲 / 长时间卡顿）→ 直接落位；
 * - 其余误差按受限速率消化（每帧最多 `slew × dt`，即速度只偏离 1 倍
 *   [fineSlew] / [coarseSlew] 的量级），人眼看到的是连续速度而非阶跃。
 *
 * [transitMs] 为样本从「生效时刻」到「到达时刻」的延迟（由调用方用墙上时钟
 * 算好并夹取）：纠偏前先把样本外推到当前时刻，固定延迟不再进入时基。
 * 纯逻辑、`now` 由调用方注入，可脱离渲染树验证。
 */
internal class LyricClock(
    private val fineErrorMs: Long = 100L,
    private val fineSlew: Float = 0.10f,
    private val coarseSlew: Float = 0.20f,
    private val hardSnapMs: Long = 300L,
) {
    private var positionMs = 0.0
    private var lastAdvanceUptimeMs = 0L
    private var samplePositionMs = 0L
    private var sampleAnchorUptimeMs = 0L
    private var playing = false
    private var hasSample = false

    /** 最近一次采样的相位误差（毫秒；正 = 本地落后于样本）。调试 / 日志用。 */
    var lastErrorMs = 0L
        private set

    /** 上次采样以来推进过的帧数与最后一帧间隔（诊断用）。 */
    var framesSinceSample = 0L
        private set
    var lastStepMs = 0L
        private set

    /** 诊断计数复位（采样对齐后调用）。 */
    fun resetStepStats() {
        framesSinceSample = 0L
        lastStepMs = 0L
    }

    /** 当前估计位置（毫秒）。 */
    val currentMs: Long
        get() = positionMs.toLong()

    /**
     * 对齐一个位置样本；返回是否发生了硬同步（落位）。
     *
     * [transitMs] 是样本延迟（≥0）：`样本 + transit` 即当前时刻的真实位置。
     */
    fun sync(
        sampleMs: Long,
        transitMs: Long,
        isPlaying: Boolean,
        nowUptimeMs: Long,
    ): Boolean {
        advanceTo(nowUptimeMs)
        val transit = transitMs.coerceIn(0L, maxTransitMs)
        // 暂停时位置不推进：延迟补偿只在播放中有意义（否则会把暂停样本
        // 外推到「当前时刻」，暂停位置凭空多出一次传输延迟）。
        val compensation = if (isPlaying) transit else 0L
        val estimateNow = sampleMs + compensation
        val error = estimateNow - positionMs
        lastErrorMs = error.toLong()
        samplePositionMs = sampleMs
        sampleAnchorUptimeMs = nowUptimeMs - compensation
        playing = isPlaying
        val snap = !hasSample || !isPlaying || abs(error) > hardSnapMs
        hasSample = true
        if (snap) positionMs = estimateNow.toDouble()
        return snap
    }

    /** 推进到 [nowUptimeMs] 并返回当前位置（毫秒）。 */
    fun advance(nowUptimeMs: Long): Long {
        advanceTo(nowUptimeMs)
        return positionMs.toLong()
    }

    private fun advanceTo(nowUptimeMs: Long) {
        if (lastAdvanceUptimeMs == 0L) {
            lastAdvanceUptimeMs = nowUptimeMs
            return
        }
        val dt = (nowUptimeMs - lastAdvanceUptimeMs).coerceIn(0L, maxFrameMs)
        lastAdvanceUptimeMs = nowUptimeMs
        if (dt == 0L || !playing) return
        lastStepMs = dt
        framesSinceSample++
        val target = samplePositionMs + (nowUptimeMs - sampleAnchorUptimeMs)
        val error = target - positionMs
        val slew = if (abs(error) <= fineErrorMs) fineSlew else coarseSlew
        val limit = (slew.toDouble() * dt).coerceAtLeast(minCorrectionMs)
        positionMs += dt + error.coerceIn(-limit, limit)
    }

    private companion object {
        /** 单帧推进上限：长时间无帧（主线程卡顿 / 冻结恢复）交给下一个样本纠正。 */
        const val maxFrameMs = 1000L

        /** 采样延迟夹取上限：墙上时钟被调整时不让时间轴整体偏移。 */
        const val maxTransitMs = 1000L

        /** 每帧最小纠偏量：dt 极小时（高刷）也保持收敛方向。 */
        const val minCorrectionMs = 0.5
    }
}

/**
 * 临界阻尼跟随：把「目标位移」平滑成速度连续（C1）的输出。
 *
 * 用二阶临界阻尼系统的闭式解递推（`e(t) = (e0 + (v0 + ω·e0)·t)·e^(−ωt)`），
 * 任意 dt 都稳定，不需要子步进。对匀速移动的目标，稳态滞后是常数
 * （≈ 2·v/ω 像素），不是抖动——高亮与文本同组位移，观感上不脱节。
 */
internal class LyricSpring(private val omega: Float = 28f) {
    private var value = 0f
    private var velocity = 0f
    private var target = 0f
    private var lastUptimeMs = 0L

    /** 是否已收敛（偏差与速度都在亚像素量级）：据此决定还要不要继续排帧。 */
    val settled: Boolean
        get() = abs(velocity) <= settledVelocity && abs(target - value) <= settledGap

    /** 直接落位（切行 / 暂停 / 尺寸变化）：不做过渡。 */
    fun snap(next: Float, nowUptimeMs: Long): Float {
        value = next
        target = next
        velocity = 0f
        lastUptimeMs = nowUptimeMs
        return value
    }

    /** 跟随到新目标并返回当前值。 */
    fun advance(next: Float, nowUptimeMs: Long): Float {
        target = next
        if (lastUptimeMs == 0L) {
            lastUptimeMs = nowUptimeMs
            return value
        }
        val dt = ((nowUptimeMs - lastUptimeMs).coerceIn(0L, maxStepMs)).toFloat() / 1000f
        lastUptimeMs = nowUptimeMs
        if (dt <= 0f) return value
        val e0 = value - target
        val v0 = velocity
        val decay = exp(-omega * dt)
        val slope = v0 + omega * e0
        value = target + (e0 + slope * dt) * decay
        velocity = (slope - omega * (e0 + slope * dt)) * decay
        return value
    }

    private companion object {
        /** 单步积分上限：卡顿后不必补算长尾，直接按稳态收敛。 */
        const val maxStepMs = 250L
        const val settledGap = 0.05f
        const val settledVelocity = 1f
    }
}
