package top.stillmisty.molia.sync

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 局域网权限通道（Android 17 / API 37 起的 `ACCESS_LOCAL_NETWORK`）。
 *
 * 为什么自有通道而不是权限库：项目只需要这一个运行时权限，而 `permission_handler`
 * 的 Windows 实现会在插件注册时创建 `Geolocator` 并订阅位置更新，导致 Windows
 * 把进程标记为「正在使用位置」（上游 #1394）。权限库的跨平台抽象在本项目里
 * 也只用到 Android 分支，收成自有通道后依赖面更小、行为完全可控。
 *
 * 状态语义与 Dart 侧 `LocalNetworkPermissionStatus` 对齐：
 * - `granted`：已授权；API 37 以下恒为 granted（系统不限制局域网）；
 * - `denied`：本次可再问（系统仍允许展示权限说明）；
 * - `permanentlyDenied`：系统不再弹窗，只能去系统设置。
 *
 * 是否「永久拒绝」需要「是否请求过」才能判定：首次请求前
 * `shouldShowRequestPermissionRationale` 同样返回 false，和「不再询问」
 * 无法区分。沿用通知权限的做法，把已请求标记写进 Flutter 的 SharedPreferences。
 */
class LocalNetworkPermissionChannelHandler(
    private val activity: Activity,
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    /// 权限请求的挂起结果：系统回调后一次性完成。
    private var pendingResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionStatus" -> result.success(permissionStatus())
            "requestPermission" -> requestPermission(result)
            "openAppSettings" -> openAppSettings(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 权限回调分发：返回 true 表示本请求属于局域网权限（调用方不再处理）。
     * 状态以系统实际授权结果为准，不直接使用 grantResults（避免多权限混淆）。
     */
    fun handlePermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pendingResult?.success(permissionStatus())
        pendingResult = null
        return true
    }

    private fun permissionStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.CINNAMON_BUN) {
            return STATUS_GRANTED
        }
        val permission = Manifest.permission.ACCESS_LOCAL_NETWORK
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return STATUS_GRANTED
        }
        val requested = context
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_REQUESTED, false)
        if (requested && !activity.shouldShowRequestPermissionRationale(permission)) {
            return STATUS_PERMANENTLY_DENIED
        }
        return STATUS_DENIED
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.CINNAMON_BUN) {
            result.success(STATUS_GRANTED)
            return
        }
        val permission = Manifest.permission.ACCESS_LOCAL_NETWORK
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(STATUS_GRANTED)
            return
        }
        if (permissionStatus() == STATUS_PERMANENTLY_DENIED) {
            result.success(STATUS_PERMANENTLY_DENIED)
            return
        }
        // 记下「已请求过」：系统回调里据此区分 denied / permanentlyDenied。
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_REQUESTED, true)
            .apply()
        // 并发请求只保留最新一个，旧回调先以 denied 结束，避免 Dart 侧挂起。
        pendingResult?.success(STATUS_DENIED)
        pendingResult = result
        activity.requestPermissions(arrayOf(permission), REQUEST_CODE)
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            )
            context.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_SETTINGS_ERROR", e.message, null)
        }
    }

    companion object {
        const val CHANNEL_NAME = "top.stillmisty.molia/local_network"
        const val REQUEST_CODE = 1003

        private const val PREFERENCES_NAME = "FlutterSharedPreferences"
        private const val KEY_REQUESTED = "flutter.sync_lan_permission_requested"

        private const val STATUS_GRANTED = "granted"
        private const val STATUS_DENIED = "denied"
        private const val STATUS_PERMANENTLY_DENIED = "permanentlyDenied"
    }
}
