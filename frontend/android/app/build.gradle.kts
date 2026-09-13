plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val nativeCryptoRoot = rootProject.layout.buildDirectory.dir("rust-android").get().asFile
val nativeCryptoFoundationJniLibs = nativeCryptoRoot.resolve("foundation/jniLibs")
val isWindowsHost = System.getProperty("os.name").lowercase().contains("windows")

fun registerRustCryptoBuild(
    taskName: String,
    cryptoProfile: String,
    outputDirectory: File,
) = tasks.register<Exec>(taskName) {
    group = "build"
    description = "Builds the pinned $cryptoProfile Rust cryptographic core for Android."
    workingDir = rootProject.projectDir.parentFile
    val toolDirectory = rootProject.projectDir.parentFile.resolve("tool")
    val nativeDirectory = rootProject.projectDir.parentFile.resolve("native/crypto_core")
    inputs.files(
        rootProject.projectDir.parentFile.resolve("rust-toolchain.toml"),
        toolDirectory.resolve("build_libsodium_android.sh"),
        toolDirectory.resolve("build_rust_android.ps1"),
        toolDirectory.resolve("build_rust_android.sh"),
        nativeDirectory.resolve("Cargo.toml"),
        nativeDirectory.resolve("Cargo.lock"),
        nativeDirectory.resolve("build.rs"),
        nativeDirectory.resolve("include/communication_crypto.h"),
        nativeDirectory.resolve("vendor/libsodium/LATEST.tar.gz"),
        nativeDirectory.resolve("vendor/libsodium/LATEST.tar.gz.minisig"),
    )
    inputs.dir(nativeDirectory.resolve("src"))
    inputs.dir(nativeDirectory.resolve("vendor/mlkem-native/mlkem"))
    outputs.dir(outputDirectory)

    if (isWindowsHost) {
        commandLine(
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            toolDirectory.resolve("build_rust_android.ps1").absolutePath,
            "all",
            cryptoProfile,
        )
    } else {
        commandLine(
            "bash",
            toolDirectory.resolve("build_rust_android.sh").absolutePath,
            "all",
            cryptoProfile,
        )
    }
}

val buildRustCryptoAndroid = registerRustCryptoBuild(
    "buildRustCryptoAndroid",
    "foundation",
    nativeCryptoFoundationJniLibs,
)

android {
    // Build-time Kotlin/resource package only. The installed identity is the
    // application ID below; this namespace is deliberately not part of it and
    // changing it would not affect upgrade compatibility.
    namespace = "com.example.communication_platform"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val productionApplicationId = "com.orviniq.chat"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        resValues = true
    }

    defaultConfig {
        applicationId = productionApplicationId
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("development") {
            dimension = "environment"
            applicationId = "$productionApplicationId.development"
            resValue("string", "app_name", "Communication Platform (Development)")
        }
        create("production") {
            dimension = "environment"
            applicationId = productionApplicationId
            resValue("string", "app_name", "Communication Platform")
        }
    }

    sourceSets.getByName("development").jniLibs.srcDir(nativeCryptoFoundationJniLibs)
    sourceSets.getByName("production").jniLibs.srcDir(nativeCryptoFoundationJniLibs)

    buildTypes {
        release {
            // Deliberately unset, and never the debug config. No flavor carries a
            // release signing identity, so Production release packages unsigned:
            // it keeps building and stays verifiable in CI, but the OS cannot
            // install it, so it cannot reach a user by accident. Production gains
            // its own identity only through an explicit approved release decision.
            signingConfig = null
        }
    }
}

// The one library this module adopts, and the complete reason for it (ADR-054).
//
// It is not an addition: `androidx.core` is already on the classpath behind the
// Flutter embedding, through androidx.activity and androidx.fragment. Declaring
// it here is what turns the *version* from an accident of transitive resolution
// into a decision, and what keeps four security boundaries off a version this
// project never chose:
//
//   * `FileProvider`, for scoped read-only attachment sharing;
//   * `NotificationCompat` / `NotificationManagerCompat` /
//     `NotificationChannelCompat`, for the message alert and the sustained
//     delivery entry - channel creation, `setPublicVersion`, visibility and
//     category across API 24-36;
//   * `ServiceCompat.startForeground` and `ContextCompat.startForegroundService`,
//     which carry the foreground-service type through the API 26/29/34 changes;
//   * `ActivityCompat.requestPermissions` /
//     `shouldShowRequestPermissionRationale`, for POST_NOTIFICATIONS.
//
// 1.16.0 rather than the newest: 1.17.0 adds nothing this application uses, and
// 1.18.0 raises the required compileSdk to 36.1 while this toolchain compiles at
// `flutter.compileSdkVersion` (36). Moving it therefore means moving the Android
// SDK and re-reviewing a new AndroidX set, and must not happen as a side effect
// of a plugin upgrade - which is why the resolved set below is locked.
dependencies {
    implementation("androidx.core:core:1.16.0")
}

// ---------------------------------------------------------------------------
// The resolved set is part of the decision, so it is recorded and enforced.
// ---------------------------------------------------------------------------
//
// `pubspec.lock` plus `flutter pub get --enforce-lockfile` pins the Dart half.
// Nothing pinned the Android half: every version above is static, so resolution
// was deterministic, but a new plugin, a new transitive arrival or a silently
// raised conflict resolution would simply have appeared in the artifact. It has
// happened already - connectivity_plus 7.1.0 and later declare
// `androidx.core:core:1.18.0`, which would have carried this module's pin
// upwards without a line of this file changing.
//
// These are the configurations that decide what a built artifact contains, and
// `android/app/gradle.lockfile` records exactly what each resolves to. STRICT
// mode means a configuration named here with no recorded state fails the build
// rather than resolving unconstrained. Regenerate deliberately, never
// reflexively, with:
//
//   ./gradlew :app:writeDependencyLocks --write-locks
//
val lockedConfigurations =
    setOf(
        "developmentDebugCompileClasspath",
        "developmentDebugRuntimeClasspath",
        "productionReleaseCompileClasspath",
        "productionReleaseRuntimeClasspath",
    )

dependencyLocking {
    lockMode.set(LockMode.STRICT)
}

configurations.configureEach {
    if (name in lockedConfigurations) {
        resolutionStrategy.activateDependencyLocking()
    }
}

tasks.register("writeDependencyLocks") {
    group = "verification"
    description = "Resolves every locked configuration so --write-locks can record it."
    val resolvable = lockedConfigurations.map { configurations.named(it) }
    doLast {
        resolvable.forEach { it.get().incoming.resolutionResult.allComponents }
    }
}

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
        dependsOn(buildRustCryptoAndroid)
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
