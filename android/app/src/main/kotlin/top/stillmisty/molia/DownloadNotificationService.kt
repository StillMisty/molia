package top.stillmisty.molia

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

private const val TAG = "MoliaDownloadNotify"
private const val NOTIFICATION_CHANNEL_ID = "molia_downloads"

/// 下载通知中心：任务状态 + 通知构建 + 前台服务（dataSync）启停。
///
/// 分工（Dart 侧见 `lib/data/downloads/download_notifications*.dart`）：
/// - Dart 只传生命周期（start / update / stop）与结构化数据（曲目名 / 歌手 /
///   批量位置 / 进度）；静态文案用本应用的 Android 资源（en / zh）组装；
/// - 本文件负责通知与前台服务，**失败一律 no-op 只记日志**：通知发不出来不影响
///   下载本身（下载在 Dart 侧继续跑）。
///
/// 降级：API 33+ 未授予 POST_NOTIFICATIONS（或用户在系统里关掉本应用通知）时
/// 不启动前台服务、也不发通知——否则会留下「没有可见通知的前台服务」，部分 ROM
/// 会限制 / 提示；此时下载照常进行（与没有本功能前完全一致）。
///
/// 线程：全部状态只在主线程访问（MethodChannel 回调、Service 与 Handler 回调
/// 都在主线程）。
object DownloadNotifications {
    /// 通道名（与 Dart 侧 `kDownloadNotificationsChannel` 对齐）。
    const val CHANNEL = "top.stillmisty.molia/download_notifications"

    /// 通知 id 基数：任务在会话内顺序取号（避免字符串 hashCode 撞号）；
    /// [PLACEHOLDER_ID] 留给「前台服务契约占位」。
    private const val ID_BASE = 4200
    private const val PLACEHOLDER_ID = ID_BASE - 1

    /// 任务收尾后延迟收服务：顺序下载时下一首立刻又起通知，马上 stopSelf 会在
    /// 「服务已请求停止但还没销毁」的窗口里被再次 startForeground，
    /// 结果刚建的通知随服务一起消失。
    private const val IDLE_STOP_DELAY_MS = 800L

    private val notificationIds = HashMap<String, Int>()
    private var nextNotificationId = ID_BASE

    /// 任务 id → 状态；LinkedHashMap 保持插入序 = 前台锚点固定取第一条。
    private val tasks = linkedMapOf<String, DownloadTaskState>()

    /// 运行中的前台服务（onCreate / onDestroy 维护）。
    private var service: DownloadNotificationService? = null

    private val idleHandler = Handler(Looper.getMainLooper())
    private val stopServiceRunnable = Runnable { stopService() }

    /// 收前台服务：先摘掉引用再停——之后的新任务经 [refresh] 重新
    /// `startForegroundService`（系统会取消 pending stop 或重建服务），
    /// 不会出现「服务正在销毁，却又被 startForeground」的丢通知窗口。
    fun stopService() {
        val running = service
        service = null
        running?.stopNow()
    }

    /// 开始 / 复用一条通知（同一 id = 同一条；批量任务共享一个 id）。
    fun start(
        context: Context,
        id: String,
        title: String,
        subtitle: String,
        index: Int?,
        total: Int?,
        progress: Int?,
        max: Int?,
    ) {
        if (id.isEmpty()) return
        if (!canNotify(context)) {
            Log.i(TAG, "通知不可用（权限 / 已关闭），跳过: $id")
            return
        }
        val state = tasks.getOrPut(id) { DownloadTaskState(title) }
        if (title.isNotEmpty()) state.title = title
        state.subtitle = subtitle
        if (index != null) state.index = index
        if (total != null) state.total = total
        state.progress = progress ?: 0
        state.max = max
        idleHandler.removeCallbacks(stopServiceRunnable)
        refresh(context)
    }

    /// 更新进度 / 文案；未开始过或已收尾的 id 忽略（迟到的进度不复活通知）。
    fun update(
        context: Context,
        id: String,
        title: String?,
        subtitle: String?,
        index: Int?,
        total: Int?,
        progress: Int?,
        max: Int?,
    ) {
        val state = tasks[id] ?: return
        if (!title.isNullOrEmpty()) state.title = title
        if (subtitle != null) state.subtitle = subtitle
        if (index != null) state.index = index
        if (total != null) state.total = total
        if (progress != null) state.progress = progress
        // max 0 = 「总大小未知」：进度条回到不确定态（批量换曲目时用）。
        if (max != null) state.max = max
        refresh(context)
    }

    /// 收尾并移除通知（完成 / 失败 / 取消走同一条路径；重复调用幂等）。
    fun stop(context: Context, id: String) {
        if (tasks.remove(id) == null) return
        NotificationManagerCompat.from(context.applicationContext)
            .cancel(notificationIdFor(id))
        if (tasks.isEmpty()) {
            notificationIds.clear()
            nextNotificationId = ID_BASE
            idleHandler.removeCallbacks(stopServiceRunnable)
            idleHandler.postDelayed(stopServiceRunnable, IDLE_STOP_DELAY_MS)
        } else {
            // 停掉的正好是前台锚点：让服务改用新的第一条任务。
            service?.sync()
        }
    }

    fun attach(running: DownloadNotificationService) {
        service = running
    }

    fun detach(running: DownloadNotificationService) {
        if (service === running) service = null
    }

    /// 前台锚点通知：第一条任务（无任务返回 null）。
    fun anchorNotification(context: Context): Pair<Int, Notification>? {
        val entry = tasks.entries.firstOrNull() ?: return null
        return notificationIdFor(entry.key) to build(context, entry.value)
    }

    /// 「前台服务契约占位」通知：任务在服务起来前就收尾时的兜底
    /// （`startForegroundService` 之后必须调用一次 `startForeground`，
    /// 否则会撞 `ForegroundServiceDidNotStartInTimeException`）。
    fun placeholderNotification(context: Context): Notification =
        NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.download_notification_channel_name))
            .setContentText(context.getString(R.string.download_notification_downloading))
            .setProgress(0, 0, true)
            .build()

    const val placeholderNotificationId: Int = PLACEHOLDER_ID

    /// 建通道（每次重建：名称 / 描述跟随当前应用语言；重要性只允许下调）。
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            context.getString(R.string.download_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.download_notification_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /// 通知是否可用：API 33+ 的 POST_NOTIFICATIONS + 用户在本应用上的通知开关。
    fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    /// 状态变化后刷新通知，并按需起 / 同步前台服务。
    private fun refresh(context: Context) {
        val app = context.applicationContext
        ensureChannel(app)
        for ((taskId, state) in tasks) {
            notifyCompat(app, notificationIdFor(taskId), build(app, state))
        }
        val running = service
        if (running != null) {
            running.sync()
        } else {
            startForegroundService(app)
        }
    }

    /// 起前台服务（后台受限时降级为「只有进度通知」，下载本身不受影响）。
    private fun startForegroundService(context: Context) {
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, DownloadNotificationService::class.java),
            )
        } catch (e: Exception) {
            Log.w(TAG, "前台服务启动失败（降级为普通进度通知）", e)
        }
    }

    private fun notifyCompat(context: Context, id: Int, notification: Notification) {
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (e: Exception) {
            // 无小图标 / 权限刚被撤等：只记日志。
            Log.w(TAG, "通知发送失败（忽略）: $id", e)
        }
    }

    private fun notificationIdFor(taskId: String): Int =
        notificationIds.getOrPut(taskId) { nextNotificationId++ }

    private fun build(context: Context, state: DownloadTaskState): Notification {
        val batch = state.index != null && state.total != null
        val status = context.getString(R.string.download_notification_downloading)
        val contentTitle = if (batch) {
            context.getString(
                R.string.download_notification_batch_title,
                state.index,
                state.total,
            )
        } else {
            state.title
        }
        val builder = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(context, R.color.md_theme_primary))
            .setContentTitle(contentTitle)
            .setContentText(state.subtitle.ifEmpty { status })
            // 批量时副标题显示当前曲目；单任务时就是「正在下载」状态。
            .setSubText(if (batch) state.title else status)
            .setContentIntent(openAppIntent(context))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        val percent = progressPercent(state)
        if (percent == null) {
            builder.setProgress(0, 0, true)
        } else {
            builder.setProgress(100, percent, false)
        }
        return builder.build()
    }

    /// 进度百分比；总大小未知（null / ≤ 0）返回 null（不确定进度条）。
    private fun progressPercent(state: DownloadTaskState): Int? {
        val max = state.max ?: return null
        if (max <= 0) return null
        return ((state.progress.toLong() * 100) / max).toInt().coerceIn(0, 100)
    }

    /// 点通知回到应用（复用启动 Intent，不新起任务栈）。
    private fun openAppIntent(context: Context): PendingIntent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/// 一条下载通知的状态（Dart 侧传结构化数据，文案在 Android 侧组装）。
private class DownloadTaskState(var title: String) {
    var subtitle: String = ""
    var index: Int? = null
    var total: Int? = null
    var progress: Int = 0
    var max: Int? = null
}

/// 下载前台服务（dataSync）：进度通知 + 应用退到后台时保持进程优先级。
///
/// 服务本身只是「锚点」：通知内容全部由 [DownloadNotifications] 维护，服务负责
/// 用第一条任务的通知保持前台，任务清空后自行收掉（延迟见 IDLE_STOP_DELAY_MS）。
class DownloadNotificationService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        DownloadNotifications.attach(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 重新挂引用：服务可能在「已请求停止但还没销毁」的窗口里被再次启动
        // （新一轮下载复用了它，见 DownloadNotifications.stopService）。
        DownloadNotifications.attach(this)
        sync()
        // 不粘性：下载任务在 Dart 侧，进程被杀后重启一个空服务没有意义。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        DownloadNotifications.detach(this)
        super.onDestroy()
    }

    /// 按中心状态刷新：有任务 → 第一条任务的通知作为前台通知；无任务 → 收掉。
    ///
    /// 任何一步失败都只记日志：进度通知由中心直接发，下载本身不受影响。
    fun sync() {
        DownloadNotifications.ensureChannel(this)
        val anchor = DownloadNotifications.anchorNotification(this)
        if (anchor == null) {
            // 竞态：任务在服务起来前就收尾了。startForegroundService 之后必须调用
            // 一次 startForeground（否则撞 ForegroundServiceDidNotStartInTimeException），
            // 用占位通知满足契约后立刻收掉。
            startPlaceholderForeground()
            DownloadNotifications.stopService()
            return
        }
        val (id, notification) = anchor
        try {
            ServiceCompat.startForeground(
                this,
                id,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (e: Exception) {
            Log.w(TAG, "startForeground 失败（忽略，转为普通通知）", e)
        }
    }

    /// 收前台并自停（通知随 STOP_FOREGROUND_REMOVE 一起移除）。
    fun stopNow() {
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground 失败（忽略）", e)
        }
        stopSelf()
    }

    private fun startPlaceholderForeground() {
        try {
            ServiceCompat.startForeground(
                this,
                DownloadNotifications.placeholderNotificationId,
                DownloadNotifications.placeholderNotification(this),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (e: Exception) {
            Log.w(TAG, "占位前台通知失败（忽略）", e)
        }
    }
}
