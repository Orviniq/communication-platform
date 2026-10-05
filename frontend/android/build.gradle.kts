allprojects {
    repositories {
        google()
        mavenCentral()
        // ADR-078. flutter_webrtc links audioswitch at a git commit, and JitPack is the
        // only repository that publishes a commit as an artifact. The module is looked
        // up here and nowhere else; settings.gradle.kts keeps every JitPack declaration,
        // including the one flutter_webrtc's own build script adds, from serving
        // anything but this module.
        exclusiveContent {
            forRepository { maven("https://jitpack.io") }
            filter { includeModule("com.github.davidliu", "audioswitch") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
