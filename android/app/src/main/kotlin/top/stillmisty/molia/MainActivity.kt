package top.stillmisty.molia

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.content.FileProvider
import androidx.core.os.LocaleListCompat
import androidx.core.view.WindowCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: AudioServiceActivity() {
    private var methodChannel: MethodChannel? = null
    private var lyricsChannel: top.stillmisty.molia.lyrics.LyricsChannelHandler? = null

    /// 通知权限请求的挂起结果（Android 13+）：权限回调后一次性完成。
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        // 通知权限不在启动时请求：权限时机由 Dart 侧业务决定（首次真正播放 /
        // 首次开启歌词输出，见 services/notification_permission.dart），
        // 避免冷启动就弹窗、用户还没听到歌就先被问权限。
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // 悬浮窗权限可能在系统设置页被撤销：回前台复查并收窗。
        lyricsChannel?.onResume()
    }

    private fun handleIntent(intent: Intent?) {
        when (intent?.action) {
            "PLAY_PAUSE" -> {
                methodChannel?.invokeMethod("togglePlayPause", null)
            }
            "PREVIOUS" -> {
                methodChannel?.invokeMethod("skipToPrevious", null)
            }
            "NEXT" -> {
                methodChannel?.invokeMethod("skipToNext", null)
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Widget 控制通道
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "top.stillmisty.molia/widget")
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val songName = call.argument<String>("songName")
                    val artistName = call.argument<String>("artistName")
                    val albumArtUrl = call.argument<String>("albumArtUrl")
                    val isPlaying = call.argument<Boolean>("isPlaying")
                    
                    // 获取所有小部件ID并更新
                    val appWidgetManager = android.appwidget.AppWidgetManager.getInstance(this)
                    val appWidgetIds = appWidgetManager.getAppWidgetIds(
                        android.content.ComponentName(this, MusicWidget::class.java)
                    )
                    
                    // 更新所有小部件
                    for (appWidgetId in appWidgetIds) {
                        MusicWidget.updateAppWidget(
                            context = this,
                            appWidgetManager = appWidgetManager,
                            appWidgetId = appWidgetId,
                            songName = songName,
                            artistName = artistName,
                            albumArtUrl = albumArtUrl,
                            isPlaying = isPlaying ?: false
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        
        // 语言设置通道
        val languageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "language_channel")
        languageChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setAppLocale" -> {
                    try {
                        val languageTag = call.argument<String>("languageTag")
                        if (languageTag != null) {
                            val localeList = LocaleListCompat.forLanguageTags(languageTag)
                            AppCompatDelegate.setApplicationLocales(localeList)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGUMENT", "Language tag is null", null)
                        }
                    } catch (e: Exception) {
                        result.error("SET_LOCALE_ERROR", e.message, null)
                    }
                }
                "clearAppLocale" -> {
                    try {
                        AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CLEAR_LOCALE_ERROR", e.message, null)
                    }
                }
                "openSystemLanguageSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val intent = Intent(android.provider.Settings.ACTION_APP_LOCALE_SETTINGS).apply {
                                data = android.net.Uri.fromParts("package", packageName, null)
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.error("UNSUPPORTED", "System language settings not supported on this Android version", null)
                        }
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }
                "supportsSystemLanguageSettings" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                }
                else -> result.notImplemented()
            }
        }

        // 设备存储通道：默认音频缓存上限按设备总容量推算（容量 ÷ 128）。
        val deviceStorageChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.stillmisty.molia/device_storage"
        )
        deviceStorageChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getTotalBytes" -> {
                    try {
                        val stat = android.os.StatFs(filesDir.absolutePath)
                        result.success(stat.blockCountLong * stat.blockSizeLong)
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 歌词显示通道：桌面悬浮窗 + A2DP 状态（Android）。
        lyricsChannel = top.stillmisty.molia.lyrics.LyricsChannelHandler(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            openPermissionActivity = { intent -> startActivity(intent) },
        )

        // 通知权限通道：请求时机由 Dart 侧业务决定；被永久拒绝时给设置深链。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.stillmisty.molia/notifications"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "permissionStatus" -> result.success(notificationPermissionStatus())
                "requestPermission" -> requestNotificationPermission(result)
                "openNotificationSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 应用内更新通道：安装下载好的 APK 与「安装未知应用」授权状态。
        // 下载目录（Dart 侧 getTemporaryDirectory()/updates）与
        // res/xml/file_paths.xml 的 cache-path 对齐，FileProvider 才能把
        // 文件 URI 授权给系统安装器。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.stillmisty.molia/updater"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "supportedAbi" ->
                    result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                "canInstallPackages" ->
                    result.success(packageManager.canRequestPackageInstalls())
                "installApk" -> installApk(call.argument<String>("path"), result)
                "openInstallPermissionSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                            data = android.net.Uri.fromParts("package", packageName, null)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 把下载好的 APK 交给系统安装器。
    ///
    /// 返回 ok / needPermission / missingArchive；异常经 error 通道上报
    /// （Dart 侧统一归一化为安装失败）。
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "apk path is null", null)
            return
        }
        try {
            if (!packageManager.canRequestPackageInstalls()) {
                result.success("needPermission")
                return
            }
            val file = File(path)
            if (!file.exists()) {
                result.success("missingArchive")
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            result.success("ok")
        } catch (e: Exception) {
            result.error("INSTALL_APK_ERROR", e.message, null)
        }
    }

    /// 当前通知权限状态：granted / denied / permanentlyDenied。
    ///
    /// 「永久拒绝」判定 = 曾经请求过 + 仍未授权 + 系统不再允许展示
    /// 说明（shouldShowRequestPermissionRationale=false）；
    /// 13 以下没有该权限，恒为 granted。
    private fun notificationPermissionStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "granted"
        val permission = android.Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return "granted"
        }
        val requested = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .getBoolean("flutter.notification_permission_requested", false)
        if (requested && !shouldShowRequestPermissionRationale(permission)) {
            return "permanentlyDenied"
        }
        return "denied"
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("granted")
            return
        }
        val permission = android.Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        if (notificationPermissionStatus() == "permanentlyDenied") {
            result.success("permanentlyDenied")
            return
        }
        // 记下「已请求过」：权限回调里还要用它区分 denied / permanentlyDenied。
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .edit()
            .putBoolean("flutter.notification_permission_requested", true)
            .apply()
        notificationPermissionResult?.success("denied")
        notificationPermissionResult = result
        requestPermissions(arrayOf(permission), 1002)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1002) {
            notificationPermissionResult?.success(notificationPermissionStatus())
            notificationPermissionResult = null
        }
    }
}
