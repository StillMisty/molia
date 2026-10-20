package top.stillmisty.molia

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.content.FileProvider
import androidx.core.os.LocaleListCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    /// 公共 Downloads 里的应用子目录（与桌面 `~/Downloads/Molia`、iOS 文档
    /// 目录 `Molia/` 对齐；`Environment.DIRECTORY_DOWNLOADS` = "Download"）。
    private val publicDownloadsRelativePath = "${Environment.DIRECTORY_DOWNLOADS}/Molia"

    private var methodChannel: MethodChannel? = null
    private var lyricsChannel: top.stillmisty.molia.lyrics.LyricsChannelHandler? = null
    private var batteryChannel: top.stillmisty.molia.battery.BatteryChannelHandler? = null
    private var lanPermissionChannel:
        top.stillmisty.molia.sync.LocalNetworkPermissionChannelHandler? = null
    private var sleepTimerChannel: top.stillmisty.molia.sleep.SleepTimerChannelHandler? = null

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

        // 电池状态通道：同步调度器的省电等级判定。
        batteryChannel = top.stillmisty.molia.battery.BatteryChannelHandler(
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            context = this,
        )

        // 局域网权限通道：Android 17 起 ACCESS_LOCAL_NETWORK 需运行时申请。
        lanPermissionChannel = top.stillmisty.molia.sync.LocalNetworkPermissionChannelHandler(
            activity = this,
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )

        // Play 服务可用性通道：扫码入口门控（unbundled ML Kit 需要 GMS）。
        // 只做只读探测，无生命周期需求：通道自己持有 handler 引用。
        top.stillmisty.molia.sync.PlayServicesChannelHandler(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )

        // 定时关闭：原生 Handler 到点唤醒 Dart，补熄屏 / Doze 下 Dart timer
        // 被冻结的缺口（真正的暂停仍由 Dart 控制器执行）。
        sleepTimerChannel?.dispose()
        sleepTimerChannel = top.stillmisty.molia.sleep.SleepTimerChannelHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger
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

        // 公共下载目录通道（MediaStore Downloads 集合）：把应用私有目录里的
        // 下载副本发布到公共 Downloads，用户在文件管理器 / 其它播放器里可见。
        // API 29+ 走 MediaStore insert + openOutputStream（应用自己创建的行，
        // 无需任何存储权限）；更低版本返回 null 表示不支持（本应用 minSdk 35，
        // 实际不会走到，保留分支只作语义声明）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.stillmisty.molia/downloads"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publish" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val displayName = call.argument<String>("displayName")
                    val mimeType = call.argument<String>("mimeType")
                    if (sourcePath.isNullOrEmpty() || displayName.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "sourcePath / displayName is required", null)
                    } else {
                        result.success(publishToPublicDownloads(sourcePath, displayName, mimeType))
                    }
                }
                "remove" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrEmpty()) {
                        result.success(false)
                    } else {
                        result.success(removeFromPublicDownloads(uriString))
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 下载通知通道（Android 前台服务）：任务生命周期 start / update / stop。
        // 原生只做通知与前台服务启停，失败一律 no-op（Dart 侧还会再吞一层异常并
        // 只记日志）；未授予通知权限时降级为无通知，下载本身不受影响。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DownloadNotifications.CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> DownloadNotifications.start(
                        context = this,
                        id = call.argument<String>("id").orEmpty(),
                        title = call.argument<String>("title").orEmpty(),
                        subtitle = call.argument<String>("subtitle").orEmpty(),
                        index = call.argument<Int>("index"),
                        total = call.argument<Int>("total"),
                        progress = call.argument<Int>("progress"),
                        max = call.argument<Int>("max"),
                    )
                    "update" -> DownloadNotifications.update(
                        context = this,
                        id = call.argument<String>("id").orEmpty(),
                        title = call.argument<String>("title"),
                        subtitle = call.argument<String>("subtitle"),
                        index = call.argument<Int>("index"),
                        total = call.argument<Int>("total"),
                        progress = call.argument<Int>("progress"),
                        max = call.argument<Int>("max"),
                    )
                    "stop" -> DownloadNotifications.stop(
                        this,
                        call.argument<String>("id").orEmpty(),
                    )
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(null)
            } catch (e: Exception) {
                android.util.Log.w("MoliaDownloadNotify", "下载通知调用失败: ${call.method}", e)
                result.error("DOWNLOAD_NOTIFICATION_ERROR", e.message, null)
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        sleepTimerChannel?.dispose()
        sleepTimerChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /// 把应用私有文件发布到公共 Downloads（MediaStore），返回 content URI；
    /// 不支持（API < 29）/ 失败返回 null（Dart 侧 best-effort，只记日志）。
    ///
    /// 公共副本是**发布副本**：播放取链仍只认应用目录里的原文件，删除下载时
    /// 经 `remove` 一并删除。`IS_PENDING` 保证写入期间其它 App 读不到半成品；
    /// 失败时删掉可能已插入的行，避免公共目录残留空文件。
    private fun publishToPublicDownloads(
        sourcePath: String,
        displayName: String,
        mimeType: String?
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val source = File(sourcePath)
        if (!source.exists()) return null
        var inserted: android.net.Uri? = null
        return try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType ?: "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH, publicDownloadsRelativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            inserted = uri
            val output = contentResolver.openOutputStream(uri)
                ?: throw java.io.IOException("openOutputStream returned null")
            output.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
            }
            contentResolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null
            )
            uri.toString()
        } catch (e: Exception) {
            inserted?.let { runCatching { contentResolver.delete(it, null, null) } }
            null
        }
    }

    /// 删除公共副本；行已不存在（用户在文件管理器里删掉）也算成功（幂等）。
    private fun removeFromPublicDownloads(uriString: String): Boolean {
        return try {
            contentResolver.delete(android.net.Uri.parse(uriString), null, null)
            true
        } catch (e: Exception) {
            false
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
        if (lanPermissionChannel?.handlePermissionResult(requestCode) == true) {
            return
        }
        if (requestCode == 1002) {
            notificationPermissionResult?.success(notificationPermissionStatus())
            notificationPermissionResult = null
        }
    }
}
