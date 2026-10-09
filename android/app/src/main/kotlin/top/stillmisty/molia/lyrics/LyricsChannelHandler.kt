package top.stillmisty.molia.lyrics

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 歌词平台通道（Android）：桌面悬浮窗 + A2DP 连接状态。
 *
 * 只负责"哑"执行与状态上报：所有展示策略（暂停回退 / 无歌词回退 /
 * 格式 / 门控）已在 Dart 侧的歌词显示调度中应用。
 */
class LyricsChannelHandler(
    private val context: Context,
    messenger: BinaryMessenger,
    private val openPermissionActivity: (Intent) -> Unit,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var lastA2dp = false
    private var deviceCallbackRegistered = false

    private val controller = LyricsOverlayController(
        context = context,
        onAction = { action ->
            invokeOnMain {
                channel.invokeMethod("desktop.onAction", mapOf("action" to action))
            }
        },
        onScreenState = { on ->
            invokeOnMain {
                channel.invokeMethod("desktop.onScreenState", mapOf("on" to on))
            }
        },
    )

    init {
        channel.setMethodCallHandler(this)
        registerAudioDeviceCallback()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "desktop.isSupported" -> result.success(true)
                "desktop.canDrawOverlays" -> result.success(controller.canDrawOverlays())
                "desktop.openOverlayPermission" -> {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${context.packageName}"),
                    )
                    openPermissionActivity(intent)
                    result.success(null)
                }
                "desktop.show" -> {
                    if (!controller.canDrawOverlays()) {
                        result.error(
                            "permission_denied",
                            "overlay permission not granted",
                            null,
                        )
                        return
                    }
                    controller.show(call.arguments as? Map<*, *>)
                    result.success(null)
                }
                "desktop.update" -> {
                    controller.update(call.arguments as? Map<*, *>)
                    result.success(null)
                }
                "desktop.setConfig" -> {
                    controller.setConfig(call.arguments as? Map<*, *>)
                    result.success(null)
                }
                "desktop.hide" -> {
                    controller.hide()
                    result.success(null)
                }
                "desktop.resetPosition" -> {
                    controller.resetPosition()
                    result.success(null)
                }
                "audioRoute.isA2dpConnected" -> result.success(isA2dpConnected())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("lyrics_channel_error", e.message, null)
        }
    }

    /** 回前台复查：权限被撤销时主动收窗并向 Dart 报告。 */
    fun onResume() {
        if (controller.isShown() && !controller.canDrawOverlays()) {
            controller.hide()
            invokeOnMain {
                channel.invokeMethod(
                    "desktop.onPermissionChanged",
                    mapOf("granted" to false),
                )
            }
        }
        maybeEmitA2dpChanged()
    }

    private fun registerAudioDeviceCallback() {
        if (deviceCallbackRegistered) return
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                maybeEmitA2dpChanged()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                maybeEmitA2dpChanged()
            }
        }
        try {
            audioManager.registerAudioDeviceCallback(callback, mainHandler)
            deviceCallbackRegistered = true
        } catch (_: Exception) {
            // 无音频服务（极少数 ROM）：蓝牙门控退化为 false。
        }
    }

    private fun isA2dpConnected(): Boolean =
        try {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
            }
        } catch (_: Exception) {
            false
        }

    private fun maybeEmitA2dpChanged() {
        val connected = isA2dpConnected()
        if (connected == lastA2dp) return
        lastA2dp = connected
        invokeOnMain {
            channel.invokeMethod(
                "audioRoute.onA2dpChanged",
                mapOf("connected" to connected),
            )
        }
    }

    private fun invokeOnMain(block: () -> Unit) {
        mainHandler.post(block)
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/lyrics"
    }
}
