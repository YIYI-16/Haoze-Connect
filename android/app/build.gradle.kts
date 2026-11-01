import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStorePath = providers.environmentVariable("HAOZE_ANDROID_KEYSTORE_PATH").orNull
val releaseStorePassword = providers.environmentVariable("HAOZE_ANDROID_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("HAOZE_ANDROID_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("HAOZE_ANDROID_KEY_PASSWORD").orNull
val releaseCertificatePin = rootProject.file("release-certificate.sha256").readText().trim()

val verifyHaozeReleaseSigning by tasks.registering {
    doLast {
        if (listOf(releaseStorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
                .any { it.isNullOrBlank() }) {
            throw GradleException("Haoze release signing is required; debug signing fallback is disabled")
        }
        val expected = releaseCertificatePin
        if (!expected.matches(Regex("[0-9a-f]{64}"))) {
            throw GradleException("Invalid pinned release certificate")
        }
        try {
            val store = KeyStore.getInstance("PKCS12")
            file(releaseStorePath!!).inputStream().use {
                store.load(it, releaseStorePassword!!.toCharArray())
            }
            val certificate = store.getCertificate(releaseKeyAlias)
                ?: throw GradleException("Release certificate missing")
            val fingerprint = MessageDigest.getInstance("SHA-256")
                .digest(certificate.encoded).joinToString("") { "%02x".format(it) }
            if (fingerprint != expected ||
                store.getKey(releaseKeyAlias, releaseKeyPassword!!.toCharArray()) == null) {
                throw GradleException("Release certificate does not match the pinned identity")
            }
        } catch (_: Exception) {
            throw GradleException("Release signing validation failed; check the protected key and credentials")
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyHaozeReleaseSigning)
}

android {
    namespace = "com.follow.clash"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndkVersion.get()

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.haoze.connect.mihomo"
        minSdk = flutter.minSdkVersion
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "HAOZE_RELEASE_CERT_SHA256", "\"$releaseCertificatePin\"")
    }

    buildFeatures { buildConfig = true }

    signingConfigs {
        create("release") {
            storeType = "PKCS12"
            if (!releaseStorePath.isNullOrBlank()) {
                storeFile = file(releaseStorePath)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".dev"
        }

        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("release")

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    sourceSets {
        // Unit tests live under android/tests/ instead of each module's src/test.
        getByName("test").java.setSrcDirs(listOf("../tests/app"))
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":service"))
    implementation(project(":common"))
    implementation(project(":core"))
    implementation(libs.core.splashscreen)
    implementation(libs.gson)
    implementation(libs.smali.dexlib2) {
        exclude(group = "com.google.guava", module = "guava")
    }
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
