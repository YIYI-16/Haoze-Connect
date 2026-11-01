package com.follow.clash.update

import java.io.File

data class UpdateIdentity(
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val certificates: List<String>,
    val debuggable: Boolean = false,
)

object UpdatePolicy {
    const val productionPackage = "com.haoze.connect.mihomo"

    fun validate(installed: UpdateIdentity, candidate: UpdateIdentity,
                 expectedCode: Long, expectedVersion: String, pin: String) {
        require(!installed.debuggable && !candidate.debuggable)
        require(installed.packageName == productionPackage)
        require(candidate.packageName == installed.packageName)
        require(candidate.versionCode > installed.versionCode)
        require(candidate.versionCode == expectedCode && candidate.versionName == expectedVersion)
        require(pin.matches(Regex("[0-9a-f]{64}")))
        require(installed.certificates == listOf(pin) && candidate.certificates == listOf(pin))
    }

    fun checkedFile(cache: File, path: String): File {
        val directory = File(cache, "haoze-updates").canonicalFile
        val file = File(path).canonicalFile
        require(file.parentFile == directory && file.isFile && file.extension == "apk")
        require(file.length() in 1..(512L * 1024 * 1024))
        return file
    }
}
