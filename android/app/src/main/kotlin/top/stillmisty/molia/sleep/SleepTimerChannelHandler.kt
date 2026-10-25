package top.stillmisty.molia.sleep

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 定时关闭的原生唤醒通道。
 *
 * 为什么需要：Dart `Timer` 在熄屏 / Doze 下可能被节流甚至整段冻结；倒计时的
 * 绝对 deadline 逻辑再正确，没有一次回调也无法到点暂停。这里用主线程
 * `Handler.postDelayed` 在 deadline 唤醒 Dart；定时期间自持一个带超时的
 * partial wake lock（flutter_media_session 的前台服务不保证 CPU 常亮，
 * 部分 OEM 熄屏后会冻结进程），Dart 侧仍负责真正的暂停动作。
 *
 * 协议：
 * - `arm` { millis: Long, token: Int, keepAwake: Boolean }：覆盖旧定时；
 *   `keepAwake` 只在应用后台 / 息屏时为 true（前台屏幕亮着，Handler 不会
 *   被 Doze 冻结，长期持有 partial wake lock 只会白耗电）；
 * - `cancel`：取消；
 * - 到点回调 `fired` { token }（Dart 侧用 token 丢弃过期回调）。
 */
class SleepTimerChannelHandler(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val handler = Handler(Looper.getMainLooper())
    private val powerManager =
        context.applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
    private val wakeLock: PowerManager.WakeLock? =
        powerManager?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)?.apply {
            setReferenceCounted(false)
        }
    private var pending: Runnable? = null
    private var token = 0

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "arm" -> {
                val millis = call.argument<Number>("millis")?.toLong() ?: 0L
                token = call.argument<Int>("token") ?: 0
                val keepAwake = call.argument<Boolean>("keepAwake") ?: true
                schedule(millis, keepAwake)
                result.success(null)
            }
            "cancel" -> {
                cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun schedule(millis: Long, keepAwake: Boolean) {
        cancel()
        if (millis <= 0L) return
        // 前台不持锁：屏幕亮着时主线程 Handler 正常调度；退后台 / 息屏由
        // Dart 的生命周期补检重新 arm 并带上 keepAwake=true。
        if (keepAwake) acquireWakeLock(millis) else releaseWakeLock()
        val firedToken = token
        val runnable = Runnable {
            pending = null
            releaseWakeLock()
            try {
                channel.invokeMethod("fired", firedToken)
            } catch (e: Exception) {
                // Engine 已 detach / 进程正在收尾：无需恢复，Dart 回前台补检兜底。
                android.util.Log.w("MoliaSleepTimer", "原生定时回调失败", e)
            }
        }
        pending = runnable
        handler.postDelayed(runnable, millis)
    }

    private fun acquireWakeLock(millis: Long) {
        val lock = wakeLock ?: return
        if (lock.isHeld) lock.release()
        // 多留 5s 容错：定时回调本身也要一点时间才能跑完暂停动作。
        lock.acquire(millis + 5_000L)
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        if (lock.isHeld) lock.release()
    }

    private fun cancel() {
        pending?.let { handler.removeCallbacks(it) }
        pending = null
        releaseWakeLock()
    }

    /** Engine 释放时取消回调并摘掉通道处理器。 */
    fun dispose() {
        cancel()
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/sleep_timer"
        private const val WAKE_LOCK_TAG = "Molia:SleepTimer"
    }
}
