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
 *
 * 生命周期：窗口所有权挂在进程级 [LyricsOverlayHost] 上，本 handler 只持有
 * 自己那一份 controller。引擎销毁（Activity 退出 / 重建）时必须 [dispose]，
 * 否则窗口会留在屏幕上显示旧歌词，新引擎再建一个就变成双窗口叠字。
 */
class LyricsChannelHandler(
    context: Context,
    messenger: BinaryMessenger,
    private val openPermissionActivity: (Intent) -> Unit,
) : MethodChannel.MethodCallHandler {

    private val appContext = context.applicationContext ?: context
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var lastA2dp = false
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private var disposed = false

    private val controller = LyricsOverlayHost.acquire(
        context = appContext,
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

    /**
     * 释放窗口与系统回调。幂等；重复调用（Activity onDestroy 与引擎
     * cleanup 先后触发）不会误伤新引擎的窗口。
     */
    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        audioDeviceCallback?.let { callback ->
            try {
                audioManager.unregisterAudioDeviceCallback(callback)
            } catch (_: Exception) {
            }
        }
        audioDeviceCallback = null
        LyricsOverlayHost.release(controller)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "lyrics channel disposed", null)
            return
        }
        try {
            when (call.method) {
                "desktop.isSupported" -> result.success(true)
                "desktop.canDrawOverlays" -> result.success(controller.canDrawOverlays())
                "desktop.openOverlayPermission" -> {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${appContext.packageName}"),
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
                "desktop.clear" -> {
                    controller.clear(call.arguments as? Map<*, *>)
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

    /**
     * 回前台复查：把权限事实与窗口是否存在一起上报。
     *
     * 不能只在「权限被撤销且窗口还在」时上报：Android 可能在权限撤销瞬间
     * 直接移除窗口，此时 isShown 已经是 false，Dart 会一直以为窗口在显示。
     * 每次 resume 都发一次，`shown` 让 Dart 以原生事实校正 `_shown`。
     */
    fun onResume() {
        if (disposed) return
        val granted = controller.canDrawOverlays()
        if (!granted && controller.isShown()) {
            controller.hide()
        }
        invokeOnMain {
            if (disposed) return@invokeOnMain
            channel.invokeMethod(
                "desktop.onPermissionChanged",
                mapOf("granted" to granted, "shown" to controller.isShown()),
            )
        }
        maybeEmitA2dpChanged()
    }

    private fun registerAudioDeviceCallback() {
        if (audioDeviceCallback != null) return
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
            audioDeviceCallback = callback
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
        if (disposed) return
        val connected = isA2dpConnected()
        if (connected == lastA2dp) return
        lastA2dp = connected
        invokeOnMain {
            if (disposed) return@invokeOnMain
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
