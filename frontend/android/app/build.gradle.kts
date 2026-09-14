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

// The production release identity lives in source control and holds no secret
// (ADR-076 D2). Reading the application ID from it rather than restating it here
// means the built artifact and `tool/verify_release_apk.sh` can never disagree
// about which application this is.
val productionReleaseIdentityFile = rootProject.file("production-release-identity.properties")
val productionApplicationId =
    run {
        if (!productionReleaseIdentityFile.isFile) {
            throw GradleException(
                "Missing ${productionReleaseIdentityFile.name}. The production application " +
                    "identity must stay in source control; see ADR-076 in docs/decisions.md.",
            )
        }
        val identity = Properties()
        productionReleaseIdentityFile.inputStream().use { identity.load(it) }
        identity.getProperty("application.id")?.trim().orEmpty().ifEmpty {
            throw GradleException(
                "application.id is missing from ${productionReleaseIdentityFile.name}. It is " +
                    "frozen at the first install on any device and cannot be defaulted.",
            )
        }
    }

// Production signing material (ADR-076 D5). It is never stored in this repository
// and has no default location: it comes either from the untracked properties file
// that CP_PRODUCTION_SIGNING_PROPERTIES names, or from the four
// CP_PRODUCTION_KEYSTORE_* and CP_PRODUCTION_KEY_* variables. Absent material yields
// no signing config, and `requireProductionReleaseSigning` below turns that into a
// hard failure unless the build explicitly asks for an unsigned package.
val productionSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

val productionSigningEnvironmentNames =
    mapOf(
        "storeFile" to "CP_PRODUCTION_KEYSTORE_FILE",
        "storePassword" to "CP_PRODUCTION_KEYSTORE_PASSWORD",
        "keyAlias" to "CP_PRODUCTION_KEY_ALIAS",
        "keyPassword" to "CP_PRODUCTION_KEY_PASSWORD",
    )

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

val productionSigningPropertiesFile: File? =
    System.getenv("CP_PRODUCTION_SIGNING_PROPERTIES")?.trim()?.takeIf { it.isNotEmpty() }?.let { configured ->
        val file = File(normalizeMaterialPath(configured))
        if (!file.isAbsolute) {
            // A relative path would resolve against whichever directory the Gradle
            // daemon happened to start in, which is not reproducible and can lie
            // inside the working tree.
            throw GradleException(
                "CP_PRODUCTION_SIGNING_PROPERTIES must be an absolute path, but is '$configured'.",
            )
        }
        file
    }

val productionSigningMaterial: Map<String, String>? =
    run {
        val propertiesFile = productionSigningPropertiesFile
        val fromEnvironment =
            productionSigningEnvironmentNames.mapValues { (_, name) -> System.getenv(name)?.trim().orEmpty() }
        val presentInEnvironment = fromEnvironment.filterValues { it.isNotEmpty() }

        when {
            presentInEnvironment.isNotEmpty() && propertiesFile != null -> {
                // Two sources name the key at once. Neither may silently win.
                val named =
                    productionSigningEnvironmentNames
                        .filterKeys { it in presentInEnvironment }
                        .values
                        .sorted()
                throw GradleException(
                    "Production signing material is named twice: by CP_PRODUCTION_SIGNING_PROPERTIES " +
                        "and by ${named.joinToString(", ")}. Supply one of the two.",
                )
            }
            presentInEnvironment.size == productionSigningEnvironmentNames.size -> {
                val storeFile = File(normalizeMaterialPath(fromEnvironment.getValue("storeFile")))
                if (!storeFile.isAbsolute) {
                    // A relative path would resolve against whatever directory the
                    // build happened to start in, which is not reproducible.
                    throw GradleException(
                        "CP_PRODUCTION_KEYSTORE_FILE must be an absolute path, but is " +
                            "'${fromEnvironment.getValue("storeFile")}'.",
                    )
                }
                fromEnvironment
            }
            presentInEnvironment.isNotEmpty() -> {
                // Partial configuration is always a mistake. Never sign with half
                // an intent.
                val missing =
                    productionSigningEnvironmentNames
                        .filterKeys { it !in presentInEnvironment }
                        .values
                        .sorted()
                throw GradleException(
                    "Incomplete production signing environment. Missing: ${missing.joinToString(", ")}.",
                )
            }
            propertiesFile == null -> null
            !propertiesFile.isFile -> {
                throw GradleException(
                    "CP_PRODUCTION_SIGNING_PROPERTIES names ${propertiesFile.path}, which is not a " +
                        "file. If the untracked properties file is lost, RESTORE.txt inside each " +
                        "encrypted backup of the production keystore says how to write it again.",
                )
            }
            else -> {
                val properties = Properties()
                propertiesFile.inputStream().use { properties.load(it) }
                val values =
                    productionSigningKeys.associateWith { properties.getProperty(it)?.trim().orEmpty() }
                val missing = values.filterValues { it.isEmpty() }.keys.sorted()
                if (missing.isNotEmpty()) {
                    throw GradleException(
                        "${propertiesFile.name} is incomplete. Missing: ${missing.joinToString(", ")}.",
                    )
                }
                values
            }
        }
    }

val productionSigningStoreFile: File? =
    productionSigningMaterial?.getValue("storeFile")?.let { configured ->
        val path = normalizeMaterialPath(configured)
        val candidate = File(path)
        // A file-supplied relative path resolves against the file that named it.
        if (candidate.isAbsolute) candidate else File(productionSigningPropertiesFile?.parentFile, path)
    }

// Only exactly "1" asks for an unsigned production package. Any other value is
// refused rather than guessed at.
val productionUnsignedBuildRequest = System.getenv("CP_PRODUCTION_UNSIGNED_BUILD")?.trim().orEmpty()

android {
    // Build-time Kotlin/resource package only. The installed identity is the
    // application ID below; this namespace is deliberately not part of it and
    // changing it would not affect upgrade compatibility.
    namespace = "com.example.communication_platform"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        resValues = true
    }

    signingConfigs {
        if (productionSigningMaterial != null) {
            // The persistent production release identity (ADR-076 D2). It is created
            // once and never replaced: no other key can update an install this one
            // signed (ADR-076 D4).
            create("production") {
                storeFile = productionSigningStoreFile
                storePassword = productionSigningMaterial.getValue("storePassword")
                keyAlias = productionSigningMaterial.getValue("keyAlias")
                keyPassword = productionSigningMaterial.getValue("keyPassword")
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
        create("production") {
            dimension = "environment"
            // Frozen at the first install on any device, like the signing key. Once
            // anything is installed, never edit the identity file this comes from:
            // a change forces every install through an uninstall that destroys its
            // local state irrecoverably.
            applicationId = productionApplicationId
            resValue("string", "app_name", "Communication Platform")
            if (productionSigningMaterial != null) {
                // Attached at flavor level, not build-type level, so that only
                // production gains the persistent release identity. A build type's
                // own signing config wins over the flavor's, and both `debug` and the
                // Flutter-created `profile` type (which does initWith(debug)) carry
                // the debug config, so this reaches productionRelease alone.
                // Developers never need the release keystore.
                signingConfig = signingConfigs.getByName("production")
            }
        }
    }

    sourceSets.getByName("development").jniLibs.srcDir(nativeCryptoFoundationJniLibs)
    sourceSets.getByName("production").jniLibs.srcDir(nativeCryptoFoundationJniLibs)

    buildTypes {
        release {
            // Deliberately unset, and never the debug config. The release signing
            // identity is attached to the production flavor above, so only
            // productionRelease is signed with it. Without the key,
            // requireProductionReleaseSigning fails that build unless
            // CP_PRODUCTION_UNSIGNED_BUILD=1 asks for an unsigned package, which the
            // OS refuses to install (ADR-076 D6).
            signingConfig = null
        }
    }
}

// Fail closed (ADR-076 D6). Without this, a missing key would quietly produce an
// unsigned production artifact that looks like a release build.
val requireProductionReleaseSigning =
    tasks.register("requireProductionReleaseSigning") {
        group = "verification"
        description =
            "Fails unless productionRelease is signed by the persistent production identity " +
                "or explicitly requested unsigned."
        doLast {
            if (productionUnsignedBuildRequest.isNotEmpty() && productionUnsignedBuildRequest != "1") {
                throw GradleException(
                    "CP_PRODUCTION_UNSIGNED_BUILD must be 1 or unset, but is " +
                        "'$productionUnsignedBuildRequest'.",
                )
            }
            val unsignedBuildRequested = productionUnsignedBuildRequest == "1"
            if (productionSigningMaterial != null && unsignedBuildRequested) {
                throw GradleException(
                    """
                    CP_PRODUCTION_UNSIGNED_BUILD=1 asks for an unsigned package, but production
                    signing material is configured as well. Nobody can mean both, so this
                    build does neither.

                    To sign, unset CP_PRODUCTION_UNSIGNED_BUILD. To package unsigned, remove
                    CP_PRODUCTION_SIGNING_PROPERTIES and every CP_PRODUCTION_KEYSTORE_* and
                    CP_PRODUCTION_KEY_* variable from the build's environment.
                    """.trimIndent(),
                )
            }
            if (productionSigningMaterial != null && productionSigningStoreFile?.isFile != true) {
                throw GradleException(
                    """
                    The production keystore was configured but does not exist.

                      configured: ${productionSigningMaterial.getValue("storeFile")}
                      resolved:   ${productionSigningStoreFile?.absolutePath}

                    Give storeFile a path this JVM can resolve. On Windows that means a drive
                    letter, so write C:/Users/you/key.p12 rather than the POSIX
                    /c/Users/you/key.p12 that Git Bash reports; forward slashes are correct,
                    because a backslash is an escape character in a properties file.

                    If the keystore itself is gone, restore it from one of its encrypted
                    backups: RESTORE.txt inside each archive gives the steps. Only the
                    original key can update an install it signed (ADR-076 D4).
                    """.trimIndent(),
                )
            }
            if (productionSigningMaterial == null && !unsignedBuildRequested) {
                throw GradleException(
                    """
                    productionRelease has no signing key, so this build would package an
                    unsigned artifact that looks like a release.

                    Supply the persistent production key (ADR-076 D5) one of two ways:

                      1. CP_PRODUCTION_SIGNING_PROPERTIES, the absolute path of the untracked
                         properties file holding storeFile, storePassword, keyAlias and
                         keyPassword; or
                      2. all four of CP_PRODUCTION_KEYSTORE_FILE (an absolute path),
                         CP_PRODUCTION_KEYSTORE_PASSWORD, CP_PRODUCTION_KEY_ALIAS and
                         CP_PRODUCTION_KEY_PASSWORD.

                    A build that must stay unsigned, such as CI, sets
                    CP_PRODUCTION_UNSIGNED_BUILD=1 instead; the OS refuses to install what
                    it produces. If the key cannot be found, restore it from one of its
                    encrypted backups: only the original key can update an install it
                    signed (ADR-076 D4).
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
    // validateSigningProductionRelease is included so this guard's message wins over
    // AGP's, which reports only the resolved path and not what was configured.
    if (name in setOf(
            "validateSigningProductionRelease",
            "packageProductionRelease",
            "assembleProductionRelease",
            "bundleProductionRelease",
        )
    ) {
        dependsOn(requireProductionReleaseSigning)
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
