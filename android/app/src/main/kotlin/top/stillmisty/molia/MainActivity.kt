package top.stillmisty.molia

import android.content.ComponentCallbacks2
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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var methodChannel: MethodChannel? = null
    private var lyricsChannel: top.stillmisty.molia.lyrics.LyricsChannelHandler? = null
    private var batteryChannel: top.stillmisty.molia.battery.BatteryChannelHandler? = null
    private var lanPermissionChannel:
        top.stillmisty.molia.sync.LocalNetworkPermissionChannelHandler? = null
    private var sleepTimerChannel: top.stillmisty.molia.sleep.SleepTimerChannelHandler? = null
    private var safChannel: top.stillmisty.molia.saf.SafChannelHandler? = null

    /// 公共 Downloads 发布逻辑的唯一实现；旧通道与 Pigeon host 共用。
    private val downloadsPublisherHost by lazy {
        top.stillmisty.molia.downloads.DownloadsPublisherHost(applicationContext)
    }

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

    /// Flutter 3.50 把所有 `level >= TRIM_MEMORY_RUNNING_LOW(10)` 的
    /// `onTrimMemory` 都映射成 Dart 的 `didHaveMemoryPressure`。但 Android 14+
    /// 实际只送 `UI_HIDDEN(20)` / `BACKGROUND(40)`，于是每次退后台 / 回前台都会
    /// 被误判成「系统低内存」（12GB 设备也会刷出大量日志）。
    ///
    /// 这里只把真正的 running-low / critical 交给 Flutter；`UI_HIDDEN` /
    /// `BACKGROUND` 仍手动转给渲染器与平台视图，保留 GPU / 纹理回收，但不触发
    /// Dart 的低内存清理。Dart 侧的去抖 / 过渡窗口继续作为 OEM 误报的兜底。
    override fun onTrimMemory(level: Int) {
        val lifecycleOnly = level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN
        android.util.Log.i("MoliaMemory", "onTrimMemory level=$level lifecycleOnly=$lifecycleOnly")
        if (!lifecycleOnly) {
            super.onTrimMemory(level)
            return
        }
        val engine = flutterEngine ?: return
        // 与 FlutterActivityAndFragmentDelegate.onTrimMemory 保持一致：跳过
        // Dart 的 memoryPressure 消息，但仍让渲染器 / 平台视图释放资源。
        engine.renderer.onTrimMemory(level)
        engine.platformViewsController.onTrimMemory(level)
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

        // JNI 互操作对象（StatFs / 电池）尽早拿到 applicationContext：
        // Dart 侧可能在首帧前就查询缓存上限 / 电量（ADR-0038 阶段 2）。
        top.stillmisty.molia.interop.SystemInterop.initialize(applicationContext)

        // Widget 的 Pigeon native interop host（issue #78，preview 试点）。
        // 实现只持有 applicationContext；Dart 侧失败会回退下面的旧通道。
        top.stillmisty.molia.pigeon.WidgetApiRegistrar().register(
            top.stillmisty.molia.pigeon.WidgetApiImpl(applicationContext),
            flutterEngine,
        )

        // Widget 控制通道（Pigeon 失败时的 fallback，契约稳定前不删）
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "top.stillmisty.molia/widget")
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    MusicWidgetUpdater.update(
                        context = this,
                        songName = call.argument<String>("songName"),
                        artistName = call.argument<String>("artistName"),
                        albumArtUrl = call.argument<String>("albumArtUrl"),
                        isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                    )
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
                    // 与 JNI 共用 SystemInterop 的 StatFs 读取；失败返回 -1 由
                    // Dart 侧按「未知」回退默认缓存上限。
                    result.success(
                        top.stillmisty.molia.interop.SystemInterop.totalBytes()
                    )
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

        // 定时关闭：原生 Handler 到点唤醒 Dart，补熄屏 / Doze 下 Dart timer
        // 被冻结的缺口（真正的暂停仍由 Dart 控制器执行）。
        sleepTimerChannel?.dispose()
        sleepTimerChannel = top.stillmisty.molia.sleep.SleepTimerChannelHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger
        )

        // SAF（本地曲库音乐文件夹）：树枚举 / stat / 只读字节读取。
        // picker 的 lifetime 授权由 file_picker 负责持久化，这里只消费 URI。
        safChannel?.dispose()
        safChannel = top.stillmisty.molia.saf.SafChannelHandler(
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            context = this,
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
        //
        // Pigeon `DownloadsPublisherApi` 是主路径（issue #80）；本通道保留为
        // fallback，两者共用 downloadsPublisherHost，逻辑不复制。
        top.stillmisty.molia.pigeon.DownloadsPublisherApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            top.stillmisty.molia.pigeon.DownloadsPublisherImpl(applicationContext),
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.stillmisty.molia/downloads"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publicRoot" -> {
                    result.success(downloadsPublisherHost.publicRoot())
                }
                "publish" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val displayName = call.argument<String>("displayName")
                    val mimeType = call.argument<String>("mimeType")
                    val relativeDir = call.argument<String>("relativeDir")
                    if (sourcePath.isNullOrEmpty() || displayName.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "sourcePath / displayName is required", null)
                    } else {
                        result.success(
                            downloadsPublisherHost.publish(
                                sourcePath,
                                displayName,
                                mimeType,
                                relativeDir,
                            )
                        )
                    }
                }
                "remove" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrEmpty()) {
                        result.success(false)
                    } else {
                        result.success(downloadsPublisherHost.remove(uriString))
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
                        channel = call.argument<String>("channel"),
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
                // ABI 由 Dart 侧 `Abi.current()` 纯 Dart 读取（ADR-0038），
                // 这里不再维护第二份 `Build.SUPPORTED_ABIS` 映射。
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
        safChannel?.dispose()
        safChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
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
