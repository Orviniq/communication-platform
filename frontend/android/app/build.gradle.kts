// `java` resolves to the Java plugin extension inside a project build script, so
// the JDK package has to be imported rather than fully qualified inline.
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val nativeCryptoRoot = rootProject.layout.buildDirectory.dir("rust-android").get().asFile
val nativeCryptoFoundationJniLibs = nativeCryptoRoot.resolve("foundation/jniLibs")
val nativeCryptoBetaJniLibs = nativeCryptoRoot.resolve("beta/jniLibs")
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
val buildRustCryptoAndroidBeta = registerRustCryptoBuild(
    "buildRustCryptoAndroidBeta",
    "beta",
    nativeCryptoBetaJniLibs,
)

// The frozen Beta release identity lives in source control and holds no secret.
// Reading the application ID from it rather than repeating it here means the
// built artifact and `tool/verify_release_apk.sh` can never disagree about which
// application this is.
val betaReleaseIdentityFile = rootProject.file("beta-release-identity.properties")
val betaApplicationId =
    run {
        if (!betaReleaseIdentityFile.isFile) {
            throw GradleException(
                "Missing ${betaReleaseIdentityFile.name}. The frozen Beta application " +
                    "identity must stay in source control; see docs/release-signing.md.",
            )
        }
        val identity = Properties()
        betaReleaseIdentityFile.inputStream().use { identity.load(it) }
        identity.getProperty("application.id")?.trim().orEmpty().ifEmpty {
            throw GradleException(
                "application.id is missing from ${betaReleaseIdentityFile.name}. It is " +
                    "frozen at the first external Beta install and cannot be defaulted.",
            )
        }
    }

// Private Beta signing material. It is never stored in this repository: it comes
// either from the environment (a future CI runner) or from an untracked
// properties file next to this build (a maintainer workstation). Absent material
// yields a null signing config, and `requireBetaReleaseSigning` below turns that
// into a hard failure rather than an unsigned or debug-signed Beta artifact.
val betaSigningPropertiesFile =
    System.getenv("CP_BETA_SIGNING_PROPERTIES")?.trim()?.takeIf { it.isNotEmpty() }?.let(::File)
        ?: rootProject.file("beta-signing.properties")

val betaSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

// Git Bash and other POSIX shells on Windows hand out paths like
// /c/Users/name/key.p12. Java does not consider those absolute, because a
// Windows absolute path needs a drive letter, so left alone they get resolved
// against whatever directory happens to be at hand. Map them back to C:/... so
// a path that is obviously absolute to the person who typed it is absolute here
// too. Forward slashes are kept deliberately: a backslash is an escape
// character to Properties.load().
fun normalizeMaterialPath(path: String): String {
    if (!isWindowsHost) {
        return path
    }
    val posixDrivePath = Regex("^/([A-Za-z])/(.*)$").matchEntire(path)
        ?: return path
    return "${posixDrivePath.groupValues[1].uppercase()}:/${posixDrivePath.groupValues[2]}"
}

val betaSigningMaterial: Map<String, String>? =
    run {
        val environmentNames =
            mapOf(
                "storeFile" to "CP_BETA_KEYSTORE_FILE",
                "storePassword" to "CP_BETA_KEYSTORE_PASSWORD",
                "keyAlias" to "CP_BETA_KEY_ALIAS",
                "keyPassword" to "CP_BETA_KEY_PASSWORD",
            )
        val fromEnvironment =
            environmentNames.mapValues { (_, name) -> System.getenv(name)?.trim().orEmpty() }
        val presentInEnvironment = fromEnvironment.filterValues { it.isNotEmpty() }

        when {
            presentInEnvironment.size == environmentNames.size -> {
                val storeFile = File(normalizeMaterialPath(fromEnvironment.getValue("storeFile")))
                if (!storeFile.isAbsolute) {
                    // A relative path would resolve against whatever directory the
                    // build happened to start in, which is not reproducible.
                    throw GradleException(
                        "CP_BETA_KEYSTORE_FILE must be an absolute path, but is " +
                            "'${fromEnvironment.getValue("storeFile")}'.",
                    )
                }
                fromEnvironment
            }
            presentInEnvironment.isNotEmpty() -> {
                // Partial configuration is always a mistake. Never silently fall
                // back to the file, and never sign with half an intent.
                val missing =
                    environmentNames
                        .filterKeys { it !in presentInEnvironment }
                        .values
                        .sorted()
                throw GradleException(
                    "Incomplete Beta signing environment. Missing: ${missing.joinToString(", ")}.",
                )
            }
            !betaSigningPropertiesFile.isFile -> null
            else -> {
                val properties = Properties()
                betaSigningPropertiesFile.inputStream().use { properties.load(it) }
                val values =
                    betaSigningKeys.associateWith { properties.getProperty(it)?.trim().orEmpty() }
                val missing = values.filterValues { it.isEmpty() }.keys.sorted()
                if (missing.isNotEmpty()) {
                    throw GradleException(
                        "${betaSigningPropertiesFile.name} is incomplete. " +
                            "Missing: ${missing.joinToString(", ")}.",
                    )
                }
                values
            }
        }
    }

val betaSigningStoreFile: File? =
    betaSigningMaterial?.getValue("storeFile")?.let { configured ->
        val path = normalizeMaterialPath(configured)
        val candidate = File(path)
        // A file-supplied relative path resolves against the file that named it.
        if (candidate.isAbsolute) candidate else File(betaSigningPropertiesFile.parentFile, path)
    }

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

    signingConfigs {
        if (betaSigningMaterial != null) {
            // The persistent Private Beta release identity. It is created once and
            // never replaced: see docs/release-signing.md.
            create("beta") {
                storeFile = betaSigningStoreFile
                storePassword = betaSigningMaterial.getValue("storePassword")
                keyAlias = betaSigningMaterial.getValue("keyAlias")
                keyPassword = betaSigningMaterial.getValue("keyPassword")
                // minSdk 24 means every device that can install this artifact
                // verifies APK Signature Scheme v2, so the JAR signature is dead
                // weight. v3 records the signer in its own block, which is what a
                // later rotation lineage attaches to on API 28+.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
                // There is no incremental-install channel; v4 would only emit a
                // stray .idsig file that must then be distributed alongside.
                enableV4Signing = false
            }
        }
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
        create("beta") {
            dimension = "environment"
            // Frozen at the first external Beta install. Never edit this or the
            // file it comes from; a change forces every beta user through an
            // uninstall that destroys their local state irrecoverably.
            applicationId = betaApplicationId
            // "Experimental", not "Beta". The application ID is frozen and keeps
            // its .beta suffix as an opaque identifier, but the launcher label is
            // a claim to the user, and ADR-044 holds that "beta" would overstate
            // an unreviewed cryptographic stack with disposable group state.
            resValue("string", "app_name", "Communication Platform (Experimental)")
            if (betaSigningMaterial != null) {
                // Attached at flavor level, not build-type level, so that only
                // Beta gains the persistent release identity. A build type's own
                // signing config wins over the flavor's, and both `debug` and the
                // Flutter-created `profile` type (which does initWith(debug))
                // carry the debug config, so this reaches `betaRelease` alone.
                // Developers never need the release keystore.
                signingConfig = signingConfigs.getByName("beta")
            }
        }
        create("production") {
            dimension = "environment"
            applicationId = productionApplicationId
            resValue("string", "app_name", "Communication Platform")
        }
    }

    sourceSets.getByName("development").jniLibs.srcDir(nativeCryptoFoundationJniLibs)
    sourceSets.getByName("production").jniLibs.srcDir(nativeCryptoFoundationJniLibs)
    sourceSets.getByName("beta").jniLibs.srcDir(nativeCryptoBetaJniLibs)

    buildTypes {
        release {
            // Deliberately unset, and never the debug config. The release signing
            // identity is attached per flavor above so that only Beta carries one.
            // Production release therefore packages unsigned: it keeps building
            // and stays verifiable in CI, but the OS cannot install it, so it
            // cannot reach a user by accident. Production gains its own identity
            // only through an explicit approved release decision.
            signingConfig = null
        }
    }
}

// Fail closed. Without this, a missing keystore would quietly produce an
// unsigned Beta artifact that looks like a release build.
val requireBetaReleaseSigning =
    tasks.register("requireBetaReleaseSigning") {
        group = "verification"
        description = "Fails when the persistent Beta release signing identity is unavailable."
        doLast {
            if (betaSigningMaterial != null && betaSigningStoreFile?.isFile != true) {
                throw GradleException(
                    """
                    The Beta keystore was configured but does not exist.

                      configured: ${betaSigningMaterial.getValue("storeFile")}
                      resolved:   ${betaSigningStoreFile?.absolutePath}

                    Give storeFile a path this JVM can resolve. On Windows that means a
                    drive letter, so write C:/Users/you/key.p12 rather than the POSIX
                    /c/Users/you/key.p12 that Git Bash reports; forward slashes are
                    correct, because a backslash is an escape character in a properties
                    file. Do not create a replacement keystore: if the original is
                    missing, restore it from backup. See docs/release-signing.md.
                    """.trimIndent(),
                )
            }
            if (betaSigningMaterial == null) {
                throw GradleException(
                    """
                    The Beta release signing identity is not configured, so this build would
                    produce an unsigned artifact that no device can install as an update.

                    Supply it one of two ways:

                      1. Untracked file ${betaSigningPropertiesFile.absolutePath}
                         with storeFile, storePassword, keyAlias and keyPassword; or
                      2. Environment variables CP_BETA_KEYSTORE_FILE (absolute path),
                         CP_BETA_KEYSTORE_PASSWORD, CP_BETA_KEY_ALIAS, CP_BETA_KEY_PASSWORD.

                    If no Beta signing identity exists yet, create it once with
                    tool/create_beta_keystore.sh. Never generate a throwaway key for a
                    release: the first key to reach a user is the only key that can ever
                    update that install. See docs/release-signing.md.
                    """.trimIndent(),
                )
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
        "betaReleaseCompileClasspath",
        "betaReleaseRuntimeClasspath",
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
        dependsOn(
            if (name.startsWith("mergeBeta")) {
                buildRustCryptoAndroidBeta
            } else {
                buildRustCryptoAndroid
            },
        )
    }
    // validateSigningBetaRelease is included so this guard's message wins over
    // AGP's, which reports only the resolved path and not what was configured.
    if (name in setOf(
            "packageBetaRelease",
            "assembleBetaRelease",
            "bundleBetaRelease",
            "validateSigningBetaRelease",
        )
    ) {
        dependsOn(requireBetaReleaseSigning)
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
