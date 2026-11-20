import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyPropsFile = listOf(
    rootProject.file("../../keystore/keystore.properties"),
    rootProject.file("key.properties"),
).firstOrNull { it.isFile }
val keyProps = Properties().apply {
    keyPropsFile?.inputStream()?.use { load(it) }
}
val releaseStorePassword = System.getenv("KEYSTORE_PASSWORD") ?: keyProps.getProperty("storePassword")
val releaseKeyPassword = System.getenv("KEY_PASSWORD") ?: keyProps.getProperty("keyPassword") ?: releaseStorePassword
val releaseKeyAlias = System.getenv("KEYSTORE_ALIAS") ?: keyProps.getProperty("keyAlias") ?: "zichuan"
val configuredStoreFile = System.getenv("KEYSTORE") ?: keyProps.getProperty("storeFile")

// Resolve the configured keystore relative to the Gradle project, the properties
// file, or the repository root; never print signing material.
val releaseStoreFile = configuredStoreFile?.let { raw ->
    val configured = File(raw)
    if (configured.isAbsolute) configured else {
        val repoRoot = rootProject.file("../..")
        listOfNotNull(
            rootProject.file(raw),
            keyPropsFile?.parentFile?.resolve(raw),
            repoRoot.resolve(raw),
            repoRoot.resolve("keystore").resolve(raw),
        ).firstOrNull { it.isFile } ?: rootProject.file(raw)
    }
}

// Debug builds use the release key only when it is all there; they are never the build
// that should stop over a half-filled properties file.
// A password may be nothing but spaces; a path or an alias may not.
val hasWholeReleaseKey = !releaseKeyAlias.isNullOrBlank() &&
    !releaseStorePassword.isNullOrEmpty() && !releaseKeyPassword.isNullOrEmpty() &&
    releaseStoreFile?.isFile == true

// Per-ABI runtime bundles produced by runtime/build-runtime.sh.
val runtimeOut = rootProject.file("../../runtime/out")
// libtawcroot.so for the opt-in tawcroot launch method (runtime/tawcroot/build.py; missing = unavailable).
val tawcrootOut = rootProject.file("../../runtime/out-tawcroot")

// versionCode is the build minute, same encoding as tooling/build_number.py:
// (year - 2026) * 10^8 + MMDDhhmm at UTC+8. tooling/build-apk.sh passes it as
// --build-number; this covers builds that skip the script (flutter run, the
// IDE), where pubspec's `+1` placeholder would be a downgrade and make
// `flutter run` uninstall the installed app, data included.
fun buildMinuteVersionCode(): Int {
    val t = OffsetDateTime.now(ZoneOffset.ofHours(8))
    return (t.year - 2026) * 100_000_000 + t.monthValue * 1_000_000 + t.dayOfMonth * 10_000 + t.hour * 100 + t.minute
}

android {
    namespace = "io.github.ccch1mneyyy.dsh_app"
    compileSdk = flutter.compileSdkVersion
    // The device tests under src/androidTest are AndroidTestCase tests; these platform libraries
    // carry that API (no longer in android.jar). Device-test classpath only.
    useLibrary("android.test.base")
    useLibrary("android.test.runner")
    // Pin to the installed NDK: AGP 9.1.1 attempted to auto-download 28.2.13676358
    // but the download was incomplete in this environment. r28b is compatible.
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.zichuan.assistant"
        // java.nio.file (symlinks while unpacking the rootfs) needs API 26.
        minSdk = 26
        // Target 28 like Termux, so the API 29+ exec restriction on app-private
        // files does not apply to binaries inside the rootfs.
        targetSdk = 28
        versionCode = flutter.versionCode.takeIf { it > 1 } ?: buildMinuteVersionCode()
        versionName = flutter.versionName
    }

    flavorDimensions += "abi"
    productFlavors {
        create("arm64") {
            dimension = "abi"
            ndk { abiFilters += "arm64-v8a" }
        }
        create("x64") {
            dimension = "abi"
            ndk { abiFilters += "x86_64" }
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(File(tawcrootOut, "jniLibs"))
        }
        getByName("arm64") {
            assets.srcDir(File(runtimeOut, "arm64-v8a/assets"))
            jniLibs.srcDir(File(runtimeOut, "arm64-v8a/jniLibs"))
        }
        getByName("x64") {
            assets.srcDir(File(runtimeOut, "x86_64/assets"))
            jniLibs.srcDir(File(runtimeOut, "x86_64/jniLibs"))
        }
    }

    packaging {
        // proot and friends ship as lib*.so; they must be extracted to
        // nativeLibraryDir so they can be executed.
        jniLibs {
            useLegacyPackaging = true
            // sherpa_onnx_android_* 1.13.4 and ORT Android 1.27.0 each ship an ORT 1.27.0
            // (sherpa's own build): either serves both, with the same exports.
            pickFirsts += "**/libonnxruntime.so"
            // Keep the Termux binaries byte-identical to runtime/out (their hashes are in the manifest).
            keepDebugSymbols += listOf("**/libproot.so", "**/libproot-loader.so", "**/libtalloc.so", "**/libandroid-shmem.so", "**/libtawcroot.so")
        }
    }

    lint {
        // targetSdk 28 is deliberate (see docs/architecture.md); not a Play build.
        disable += "ExpiredTargetSdkVersion"
    }

    androidResources {
        noCompress += listOf("gz", "xz", "zst", "tar")
    }

    signingConfigs {
        if (hasWholeReleaseKey) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                // All three schemes: AGP drops v1 for minSdk 24+, but some installers and
                // security scanners on Chinese ROMs still read the JAR signature.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        debug {
            // tooling/dev-run.sh installs debug over the release build on a phone, data
            // kept: Android only allows that with the same key.
            if (hasWholeReleaseKey) signingConfig = signingConfigs.getByName("release")
        }
        release {
            // Use the private repository key when configured; source-only builds fall back to debug.
            signingConfig = signingConfigs.getByName(if (hasWholeReleaseKey) "release" else "debug")
            // Ours on top of Flutter's: phone control's privileged process and
            // its TLS libraries are reached by class name (see the file).
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Local JVM tests need the desktop JNI library, not Android's classes.jar.
configurations.matching { it.name.endsWith("UnitTestRuntimeClasspath") }.configureEach {
    exclude(group = "com.microsoft.onnxruntime", module = "onnxruntime-android")
}

dependencies {
    // MIT. 1.27.0 exactly: sherpa-onnx 1.13.4 (pubspec.yaml) links ORT 1.27.0's symbols.
    // 1.23.2 crashed on Snapdragon 8 Elite with Android 16 (SME, onnxruntime#27884).
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.27.0")
    testImplementation("com.microsoft.onnxruntime:onnxruntime:1.27.0")
    // Bundled Chinese OCR. SDK statistics disclosed separately; initialization is opt-in per use.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    testImplementation("junit:junit:4.13.2")
    // Android stubs do not implement JSONObject in local JVM upgrade tests.
    testImplementation("org.json:json:20240303")

    // .tar.xz support for the rootfs bundle.
    implementation("org.tukaani:xz:1.10")

    // 不打扰模式 (phone/background): a shell-uid privileged display via Shizuku or self-ADB.
    implementation("dev.rikka.shizuku:api:13.1.5")       // MIT
    implementation("dev.rikka.shizuku:provider:13.1.5")  // MIT
    implementation("com.github.MuntashirAkon:libadb-android:3.1.1") // used under its Apache-2.0 option; pulls in spake2-android (LGPL-3.0)
    implementation("org.conscrypt:conscrypt-android:2.8.0")         // Apache-2.0: libadb TLS/pairing
    // MIT: self-signed adb client cert. The same jdk15to18 family libadb-android
    // pulls in (bcprov-jdk15to18:1.81); adding jdk18on next to it duplicates every class.
    implementation("org.bouncycastle:bcpkix-jdk15to18:1.81")
    implementation("androidx.webkit:webkit:1.15.0") // Apache-2.0: web islands' force dark (webview_flutter's own version)
}
