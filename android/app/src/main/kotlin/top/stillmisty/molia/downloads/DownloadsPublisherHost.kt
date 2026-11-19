package top.stillmisty.molia.downloads

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/**
 * 公共 Downloads（MediaStore）发布逻辑，供旧 `top.stillmisty.molia/downloads`
 * 通道与 Pigeon `DownloadsPublisherApi` host 共用（issue #80）。
 *
 * 只持有 applicationContext：两种 transport 的注册都与引擎同生命周期，不能
 * 捕获 Activity。公共副本是**发布副本**，播放取链仍只认应用目录里的原文件；
 * 失败一律返回 null / false，由 Dart 侧 best-effort 处理。
 */
class DownloadsPublisherHost(context: Context) {
    private val appContext = context.applicationContext
    private val contentResolver: ContentResolver
        get() = appContext.contentResolver

    /**
     * 公共 Downloads 里的应用子目录（与桌面 `~/Downloads/Molia`、iOS 文档
     * 目录 `Molia/` 对齐；`Environment.DIRECTORY_DOWNLOADS` = "Download"）。
     */
    private val publicDownloadsRelativePath =
        "${Environment.DIRECTORY_DOWNLOADS}/Molia"

    /** 公共 Downloads 的展示根（Dart 只用于设置页 / 保存结果提示）。 */
    @Suppress("DEPRECATION")
    fun publicRoot(): String =
        File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "Molia",
        ).absolutePath

    /**
     * 把应用私有文件发布到公共 Downloads，返回 content URI；失败返回 null。
     *
     * `IS_PENDING` 保证写入期间其它 App 读不到半成品；失败时删掉可能已插入
     * 的行，避免公共目录残留空文件。[relativeDir] 是 `Molia/` 下的可选子目录
     * （导出 / 海报分类），空 = 根下。
     */
    fun publish(
        sourcePath: String,
        displayName: String,
        mimeType: String?,
        relativeDir: String?,
    ): String? {
        // minSdk 35 实际不会走到；保留分支只作语义声明（与旧通道一致）。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val source = File(sourcePath)
        if (!source.exists()) return null
        var inserted: android.net.Uri? = null
        return try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType ?: "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH, publicRelativePath(relativeDir))
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
                null,
            )
            uri.toString()
        } catch (e: Exception) {
            inserted?.let { runCatching { contentResolver.delete(it, null, null) } }
            null
        }
    }

    /** 删除公共副本；行已不存在（用户在文件管理器里删掉）也算成功（幂等）。 */
    fun remove(uriString: String): Boolean {
        return try {
            contentResolver.delete(android.net.Uri.parse(uriString), null, null)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** `Download/Molia[/<relativeDir>]`；拒绝 `..` / 绝对路径，避免越界。 */
    private fun publicRelativePath(relativeDir: String?): String {
        val segments = relativeDir
            ?.split('/')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() && it != "." && it != ".." }
            ?: emptyList()
        return if (segments.isEmpty()) {
            publicDownloadsRelativePath
        } else {
            "$publicDownloadsRelativePath/${segments.joinToString("/")}"
        }
    }
}
