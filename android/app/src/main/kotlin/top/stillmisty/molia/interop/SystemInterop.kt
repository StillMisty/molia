package top.stillmisty.molia.interop

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import android.os.StatFs
import androidx.annotation.Keep

/**
 * 系统查询互操作对象（ADR-0038 阶段 2）。
 *
 * 通道 handler 与 JNI 生成绑定共用这一份实现，避免「通道版」和「JNI 版」
 * 行为漂移。方法全部无参（[initialize] 除外）：Dart 侧不持有 `Context`，
 * 只调用生成的无参 getter。
 *
 * R8 / minify：类名与 `@JvmStatic` 方法由生成代码在运行期按字符串查找，混淆
 * 后会直接 `ClassNotFoundException` / `NoSuchMethodError`，因此类和方法都标
 * `@Keep`，并在 proguard 规则里保留整个 `interop` 包。
 */
@Keep
object SystemInterop {
    /** 保存 applicationContext，避免持有 Activity 造成泄漏。 */
    @Volatile
    private var appContext: Context? = null

    @JvmStatic
    @Keep
    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    /**
     * 应用私有文件所在分区总容量（字节）。
     *
     * 未初始化 / StatFs 失败时返回 -1：Dart 侧按「未知」处理并回退默认缓存
     * 上限，不把异常抛给 UI。
     */
    @JvmStatic
    @Keep
    fun totalBytes(): Long {
        val context = appContext ?: return UNKNOWN_TOTAL_BYTES
        return try {
            val stat = StatFs(context.filesDir.absolutePath)
            stat.blockCountLong * stat.blockSizeLong
        } catch (_: Exception) {
            UNKNOWN_TOTAL_BYTES
        }
    }

    /**
     * 电池快照：`[percent, charging?1:0, powerSave?1:0]`。
     *
     * 与通道版语义一致：注册 null receiver 读粘性广播（`ACTION_BATTERY_CHANGED`），
     * 不常驻监听；未初始化 / 无广播 / 读取失败时返回 `[-1, 0, 0]`（未知）。
     */
    @JvmStatic
    @Keep
    fun batterySnapshot(): LongArray {
        val context = appContext ?: return UNKNOWN_BATTERY
        return try {
            val intent = context.registerReceiver(
                null,
                IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            )
            if (intent == null) return UNKNOWN_BATTERY
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            longArrayOf(
                percent.toLong(),
                if (charging) 1L else 0L,
                if (powerManager?.isPowerSaveMode == true) 1L else 0L,
            )
        } catch (_: Exception) {
            UNKNOWN_BATTERY
        }
    }

    private const val UNKNOWN_TOTAL_BYTES = -1L

    private val UNKNOWN_BATTERY = longArrayOf(-1L, 0L, 0L)
}
