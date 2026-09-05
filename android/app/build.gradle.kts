import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeys = Properties()
val releaseKeysFile = rootProject.file("key.properties")
if (releaseKeysFile.exists()) {
    releaseKeysFile.inputStream().use { releaseKeys.load(it) }
}
val hasReleaseKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseKeys.getProperty(it).isNullOrBlank() }
val validateReleaseSigning by tasks.registering {
    doLast {
        if (!hasReleaseKeys || !rootProject.file(releaseKeys.getProperty("storeFile")).isFile) {
            throw GradleException("Release signing is not configured. Provide android/key.properties and a private release keystore. Debug keys are never used for release.")
        }
    }
}
tasks.configureEach {
    if (name == "preReleaseBuild") dependsOn(validateReleaseSigning)
    // AGP's host-test resource package consumes Flutter's merged assets too.
    // Declare the producer so Gradle 9 validates the real dependency graph.
    if (name == "packageDebugUnitTestForUnitTest") dependsOn("copyFlutterAssetsDebug")
}

android {
    namespace = "com.ersingundem.larenor"
    // flutter_secure_storage requires compileSdk 37; the Flutter-provided
    // default (flutter.compileSdkVersion) lags behind that.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    defaultConfig {
        applicationId = "com.ersingundem.larenor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Health Connect's stable client declares minSdk 26. The wellbeing
        // feature checks API 28 and real provider availability separately.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeys) {
            create("release") {
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
                storeFile = rootProject.file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
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

dependencies {
    implementation("androidx.health.connect:connect-client:1.1.0")
    // Official stable AndroidX release; keep all Media3 modules in lockstep.
    val media3Version = "1.11.0"
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-session:$media3Version")
    implementation("androidx.media3:media3-datasource-okhttp:$media3Version")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
