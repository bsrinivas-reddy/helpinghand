import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (gitignored): storeFile, storePassword,
// keyAlias, keyPassword. Without it a release build stops; it is never signed with the debug key.
val keystoreFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystoreFile.exists()) keystoreFile.inputStream().use { load(it) }
}

android {
    namespace = "com.helpinghand.employer.employer_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.helpinghand.employer.employer_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only built when every property is present; the release guard below reports gaps.
        if (listOf("storeFile", "storePassword", "keyAlias", "keyPassword").none { keystoreProps.getProperty(it).isNullOrBlank() }) {
            create("release") {
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }
}

gradle.taskGraph.whenReady {
    // Any release variant (flavors too): assembleFooRelease, bundleRelease, packageRelease...
    val releaseBuild = allTasks.any {
        it.project == project && Regex("^(assemble|bundle|package).*Release$").matches(it.name)
    }
    if (releaseBuild) {
        val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .filter { keystoreProps.getProperty(it).isNullOrBlank() }
        if (!keystoreFile.exists() || missing.isNotEmpty()) {
            throw GradleException(
                "Release build needs android/key.properties with: storeFile, storePassword, keyAlias, keyPassword" +
                    (if (missing.isNotEmpty() && keystoreFile.exists()) " (missing: ${missing.joinToString()})" else "")
            )
        }
        if (!rootProject.file(keystoreProps.getProperty("storeFile")).exists()) {
            throw GradleException("Release keystore file from key.properties does not exist")
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
