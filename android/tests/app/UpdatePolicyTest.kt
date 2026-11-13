package com.follow.clash.update

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UpdatePolicyTest {
    private val pin = "a".repeat(64)
    private val installed = UpdateIdentity(UpdatePolicy.productionPackage, 64003, "6.0.3", listOf(pin))
    private val candidate = installed.copy(versionCode = 64004, versionName = "6.0.4")

    @Test fun matchingProductionUpdateIsAccepted() {
        UpdatePolicy.validate(installed, candidate, 64004, "6.0.4", pin)
    }

    @Test fun packageChangesAreRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            UpdatePolicy.validate(installed, candidate.copy(packageName = "com.haoze.connect.mihomo"), 64004, "6.0.4", pin)
        }
        assertThrows(IllegalArgumentException::class.java) {
            UpdatePolicy.validate(installed.copy(packageName = "com.haoze.connect.dev"), candidate, 64004, "6.0.4", pin)
        }
    }

    @Test fun wrongOrMultipleCertificatesAreRejected() {
        for (certificates in listOf(emptyList(), listOf("b".repeat(64)), listOf(pin, pin))) {
            assertThrows(IllegalArgumentException::class.java) {
                UpdatePolicy.validate(installed, candidate.copy(certificates = certificates), 64004, "6.0.4", pin)
            }
        }
    }

    @Test fun debugSignedReleaseVariantsAreRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            UpdatePolicy.validate(installed, candidate.copy(debuggable = true), 64004, "6.0.4", pin)
        }
    }

    @Test fun wrongInstalledCertificateIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            UpdatePolicy.validate(installed.copy(certificates = listOf("b".repeat(64))), candidate, 64004, "6.0.4", pin)
        }
    }

    @Test fun nonIncreasingOrUnexpectedVersionIsRejected() {
        for (code in listOf(64002L, 64003L, 64005L)) {
            assertThrows(IllegalArgumentException::class.java) {
                UpdatePolicy.validate(installed, candidate.copy(versionCode = code), 64004, "6.0.4", pin)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            UpdatePolicy.validate(installed, candidate, 64004, "6.0.5", pin)
        }
    }

    @Test fun onlyThePrivateUpdateCacheCanSupplyAnApk() {
        val cache = Files.createTempDirectory("haoze-update-policy").toFile()
        try {
            val folder = cache.resolve("haoze-updates").apply { mkdir() }
            val apk = folder.resolve("update.apk").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            assertEquals(apk.canonicalFile, UpdatePolicy.checkedFile(cache, apk.path))
            val outside = cache.resolve("outside.apk").apply { writeBytes(byteArrayOf(1)) }
            assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.checkedFile(cache, outside.path) }
            assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.checkedFile(cache, folder.resolve("missing.apk").path) }
            val exe = folder.resolve("wrong.exe").apply { writeBytes(byteArrayOf(1)) }
            assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.checkedFile(cache, exe.path) }
        } finally {
            cache.deleteRecursively()
        }
    }
}
