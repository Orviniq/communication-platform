pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")

// ADR-078. JitPack builds whatever public repository a coordinate names, so this build
// takes exactly one module from it. build.gradle.kts declares JitPack for that module,
// but flutter_webrtc's build script also adds an unfiltered JitPack to every project.
// This rule is registered before any build script runs and reaches every JitPack
// declaration, whichever script makes it, so none of them can serve another module.
gradle.allprojects {
    repositories.withType<MavenArtifactRepository>().configureEach {
        if (url.host == "jitpack.io") {
            content { includeModule("com.github.davidliu", "audioswitch") }
        }
    }
}
