package top.stillmisty.molia.battery

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import top.stillmisty.molia.interop.SystemInterop

/**
 * 电池状态通道：供同步调度器的省电等级判定（电量 / 充电 / 系统省电模式）。
 *
 * 实现委托 [SystemInterop]：JNI 与通道共用同一份读取逻辑（ADR-0038 阶段 2）。
 * 读一次注册为 null receiver 的粘性广播（`ACTION_BATTERY_CHANGED`），
 * 不常驻监听：调度器只在等级评估时点查询。
 */
class BatteryChannelHandler(
    messenger: BinaryMessenger,
    context: Context,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        // 通道 handler 可能在 MainActivity 初始化互操作对象之前创建（测试 /
        // 嵌入式引擎），这里再兜一次；initialize 幂等。
        SystemInterop.initialize(context)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "snapshot") {
            result.notImplemented()
            return
        }
        val snapshot = SystemInterop.batterySnapshot()
        result.success(
            mapOf(
                "level" to snapshot[0].toInt(),
                "charging" to (snapshot[1] == 1L),
                "powerSave" to (snapshot[2] == 1L),
            )
        )
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/battery"
    }
}
