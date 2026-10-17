package top.stillmisty.molia.sleep

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 定时关闭的原生唤醒通道。
 *
 * 为什么需要：Dart `Timer` 在熄屏 / Doze 下可能被节流甚至整段冻结；倒计时的
 * 绝对 deadline 逻辑再正确，没有一次回调也无法到点暂停。这里用主线程
 * `Handler.postDelayed` 在 deadline 唤醒 Dart（播放中的 audio_service 前台服务
 * 已持有 partial wake lock），Dart 侧仍负责真正的暂停动作。
 *
 * 协议：
 * - `arm` { millis: Long, token: Int }：覆盖旧定时；
 * - `cancel`：取消；
 * - 到点回调 `fired` { token }（Dart 侧用 token 丢弃过期回调）。
 */
class SleepTimerChannelHandler(messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val handler = Handler(Looper.getMainLooper())
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
                schedule(millis)
                result.success(null)
            }
            "cancel" -> {
                cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun schedule(millis: Long) {
        cancel()
        if (millis <= 0L) return
        val firedToken = token
        val runnable = Runnable {
            pending = null
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

    private fun cancel() {
        pending?.let { handler.removeCallbacks(it) }
        pending = null
    }

    /** Engine 释放时取消回调并摘掉通道处理器。 */
    fun dispose() {
        cancel()
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/sleep_timer"
    }
}
