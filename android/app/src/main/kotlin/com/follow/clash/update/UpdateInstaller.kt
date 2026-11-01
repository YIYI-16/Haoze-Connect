package com.follow.clash.update

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import com.follow.clash.BuildConfig
import java.io.File
import java.security.MessageDigest

object UpdateInstaller {
    @Suppress("DEPRECATION")
    private val flags: Int
        get() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
                else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun identity(info: PackageInfo): UpdateIdentity {
        val signatures = if (Build.VERSION.SDK_INT >= 28) {
            info.signingInfo?.apkContentsSigners ?: error("Missing update signing certificate")
        } else {
            info.signatures ?: error("Missing update signing certificate")
        }
        return UpdateIdentity(
            info.packageName,
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong(),
            info.versionName ?: error("Missing update version"),
            signatures.map { signature ->
                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                    .joinToString("") { "%02x".format(it) }
            },
            (requireNotNull(info.applicationInfo).flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
        )
    }

    @Suppress("DEPRECATION")
    fun installedIdentity(context: Context): UpdateIdentity =
        identity(context.packageManager.getPackageInfo(context.packageName, flags))

    fun identityMap(context: Context): Map<String, Any> {
        val installed = installedIdentity(context)
        require(installed.certificates.size == 1)
        return mapOf("package" to installed.packageName, "versionCode" to installed.versionCode,
                     "version" to installed.versionName, "certificate" to installed.certificates.single())
    }

    @Suppress("DEPRECATION")
    fun verify(context: Context, path: String, code: Long, version: String, digest: String): File {
        val file = UpdatePolicy.checkedFile(context.cacheDir, path)
        require(digest.matches(Regex("[0-9a-f]{64}")))
        val hasher = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(65536)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                hasher.update(buffer, 0, read)
            }
        }
        require(hasher.digest().joinToString("") { "%02x".format(it) } == digest)
        val candidate = context.packageManager.getPackageArchiveInfo(file.path, flags)
            ?: error("Invalid update APK")
        UpdatePolicy.validate(installedIdentity(context), identity(candidate), code, version,
                              BuildConfig.HAOZE_RELEASE_CERT_SHA256)
        return file
    }

    fun canInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()

    fun requestPermission(activity: Activity): Boolean {
        if (canInstall(activity)) return true
        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
            data = "package:${activity.packageName}".toUri()
        })
        return true
    }

    fun launch(activity: Activity, file: File): Boolean {
        check(canInstall(activity)) { "Update installation permission is required" }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        return true
    }
}
