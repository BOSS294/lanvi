
/*
 * Project: Lanvi
 * File: android/build.gradle.kts
 * Purpose: Configure shared Android build settings.
 * Changelog: Align Android Java compilation with JVM 17.
 */

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()

rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory =
        newBuildDir.dir(project.name)

    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

/*
 * Apply Java 17 after each Android subproject's own
 * build script has configured its Android extension.
 */
subprojects {
    afterEvaluate {
        val androidExtension =
            extensions.findByName("android")
                as? com.android.build.gradle.BaseExtension

        androidExtension?.compileOptions?.apply {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
