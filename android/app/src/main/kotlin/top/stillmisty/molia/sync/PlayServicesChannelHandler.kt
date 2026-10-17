package top.stillmisty.molia.sync

import android.content.Context
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Google Play 服务可用性通道：同步配对码的扫码入口按它门控。
 *
 * 为什么需要：扫码走 `mobile_scanner` 的 **unbundled** ML Kit（识别模型由
 * Play 服务按需下载，APK 不打包模型，见 `android/gradle.properties` 的
 * `dev.steenbakker.mobile_scanner.useUnbundled` 取舍注释）。没有 GMS 的设备
 * （AOSP / 部分国产 ROM）打开扫码只会拿到「模型下载失败」的死胡同——直接在
 * 入口处隐藏，只留粘贴。
 *
 * 语义：`isAvailable` 返回 `GoogleApiAvailability.isGooglePlayServicesAvailable
 * == SUCCESS`；GMS 缺失 / 版本过旧 / 被禁用 / 任何异常一律 false（宁可少一个
 * 入口，不给死胡同）。只做只读探测，不触发修复对话框。
 */
class PlayServicesChannelHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            else -> result.notImplemented()
        }
    }

    private fun isAvailable(): Boolean = try {
        GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    } catch (_: Exception) {
        false
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/play_services"
    }
}
