import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

repositories {
    // Moonlight's pinned Shield controller extension is published by its
    // upstream GitHub project through JitPack rather than Maven Central.
    maven(url = "https://jitpack.io")
}

val freeRdpAar = file("freerdp/freeRDPCore.aar")
val freeRdpReceipt = file("freerdp/receipt.json")
val freeRdpArm64Receipt = file("freerdp/arm64-v8a-receipt.json")
val freeRdpX86Receipt = file("freerdp/x86_64-receipt.json")
val productNativeReceipt = file("product-native-receipt.json")
val productNativeSetting = providers.environmentVariable("LARENOR_PRODUCT_NATIVE_ENGINES").orNull
if (productNativeSetting != null && productNativeSetting != "required") {
    throw GradleException("LARENOR_PRODUCT_NATIVE_ENGINES must be unset or exactly 'required'")
}
val productNativeFiles = listOf(
    freeRdpAar,
    freeRdpArm64Receipt,
    freeRdpX86Receipt,
    file("moonlight/moonlight-engine.aar"),
    file("moonlight/receipt.json"),
    productNativeReceipt,
)
val hasAnyProductNativeFile = productNativeFiles.any { it.exists() }
val hasProductNative = productNativeFiles.all { it.isFile }
if (hasAnyProductNativeFile && !hasProductNative && productNativeReceipt.exists()) {
    throw GradleException("The product native engine package is incomplete")
}
if (productNativeSetting == "required" && !hasProductNative) {
    throw GradleException("The product build requires verified Moonlight and FreeRDP engine packages")
}
if (hasProductNative && freeRdpReceipt.exists()) {
    throw GradleException("The product FreeRDP package cannot be mixed with a single-ABI receipt")
}
if (!hasProductNative && freeRdpAar.exists() != freeRdpReceipt.exists()) {
    throw GradleException("FreeRDP AAR and receipt must be installed together")
}
val hasFreeRdp = hasProductNative || (freeRdpAar.isFile && freeRdpReceipt.isFile)
val verifyFreeRdpPackage by tasks.registering(Exec::class) {
    onlyIf { hasFreeRdp && !hasProductNative }
    workingDir(rootProject.projectDir.parentFile)
    commandLine(
        "python3", "tool/freerdp_android_package.py", "verify-install",
        freeRdpAar.absolutePath, freeRdpReceipt.absolutePath,
    )
}

val moonlightAar = file("moonlight/moonlight-engine.aar")
val moonlightReceipt = file("moonlight/receipt.json")
if (moonlightAar.exists() != moonlightReceipt.exists()) {
    throw GradleException("Moonlight AAR and receipt must be installed together")
}
val hasMoonlight = moonlightAar.isFile && moonlightReceipt.isFile
val verifyMoonlightPackage by tasks.registering(Exec::class) {
    onlyIf { hasMoonlight && !hasProductNative }
    workingDir(rootProject.projectDir.parentFile)
    commandLine(
        "python3", "tool/moonlight_android_package.py", "verify-install",
        moonlightAar.absolutePath, moonlightReceipt.absolutePath,
    )
}
val verifyProductNativePackage by tasks.registering(Exec::class) {
    onlyIf { hasProductNative }
    workingDir(rootProject.projectDir.parentFile)
    commandLine(
        "python3", "tool/product_android_native.py", "verify-installed",
        "--destination", projectDir.absolutePath,
    )
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
    if (name == "preBuild") {
        dependsOn(verifyFreeRdpPackage)
        dependsOn(verifyMoonlightPackage)
        dependsOn(verifyProductNativePackage)
    }
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
        isCoreLibraryDesugaringEnabled = hasMoonlight
    }

    if (hasMoonlight) {
        // Bouncy Castle's pinned modules carry the same Markdown license
        // resource. The project NOTICE/source lock retains the dependency
        // notices; duplicate JAR metadata cannot be merged into one APK path.
        packaging.resources.excludes += "/META-INF/*.md"
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            it.systemProperty(
                "larenor.f60.contract",
                rootProject.projectDir.parentFile.resolve("docs/contracts/f60-game-streaming-v2.json").canonicalPath,
            )
        }
    }

    defaultConfig {
        applicationId = "com.ersingundem.larenor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Health Connect's stable client declares minSdk 26. The wellbeing
        // feature checks API 28 and real provider availability separately.
        minSdk = if (hasFreeRdp) 29 else 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["moonlightEnabled"] = hasMoonlight.toString()
        manifestPlaceholders["moonlightTheme"] = if (hasMoonlight) "@style/StreamTheme" else "@style/LaunchTheme"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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

    if (hasFreeRdp) {
        sourceSets.getByName("main").java.srcDir("src/freerdp/kotlin")
        sourceSets.getByName("androidTest").java.srcDir("src/freerdpAndroidTest/kotlin")
    }
    if (hasMoonlight) {
        sourceSets.getByName("main").java.srcDir("src/moonlight/kotlin")
        sourceSets.getByName("test").java.srcDir("src/moonlightTest/kotlin")
        sourceSets.getByName("androidTest").java.srcDir("src/moonlightAndroidTest/kotlin")
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
    constraints {
        if (hasFreeRdp || hasMoonlight) {
            // The Flutter integration_test plugin contributes runner 1.3.0 to
            // debugRuntimeClasspath. AGP requires the instrumented-test runtime
            // to use the same version as that app runtime, so align the existing
            // transitive dependency with the stable runner used by androidTest.
            debugRuntimeOnly("androidx.test:runner:1.7.0") {
                because("the packaged native instrumentation runtime must resolve consistently with the debug app runtime")
            }
        }
    }
    if (hasFreeRdp) {
        implementation(files(freeRdpAar))
        implementation("androidx.appcompat:appcompat:1.8.0")
        implementation("androidx.core:core:1.19.0")
        implementation("androidx.preference:preference:1.2.1")
        implementation("androidx.recyclerview:recyclerview:1.4.0")
        implementation("androidx.lifecycle:lifecycle-viewmodel:2.11.0")
        implementation("androidx.lifecycle:lifecycle-livedata:2.11.0")
        implementation("androidx.room:room-runtime:2.8.5")
        implementation("net.zetetic:sqlcipher-android:4.19.0@aar")
        implementation("androidx.sqlite:sqlite:2.7.0")
    }
    if (hasMoonlight) {
        implementation(files(moonlightAar))
        coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
        implementation("com.github.cgutman:ShieldControllerExtensions:1.0.1")
        implementation("org.bouncycastle:bcpkix-jdk18on:1.85")
        implementation("org.bouncycastle:bcprov-jdk18on:1.85.2")
        implementation("org.jcodec:jcodec:0.2.5")
        implementation("org.jmdns:jmdns:3.6.3")
    }
    if (hasFreeRdp || hasMoonlight) {
        androidTestImplementation("androidx.test:core:1.7.0")
        androidTestImplementation("androidx.test:runner:1.7.0")
        androidTestImplementation("androidx.test.ext:junit:1.3.0")
    }
    implementation("com.android.tools.build:apksig:9.1.0")
    implementation("androidx.webkit:webkit:1.15.0")
    implementation("androidx.health.connect:connect-client:1.1.0")
    // Official stable AndroidX scheduler for durable, reboot-persistent work.
    implementation("androidx.work:work-runtime:2.12.0")
    // CameraX preview only: PRODUCT.CAMERA has no analyzer, capture or recorder.
    implementation("androidx.camera:camera-camera2:1.6.1")
    implementation("androidx.camera:camera-lifecycle:1.6.1")
    // Bundled on-device detector: no Google Play services model download.
    // Face detection is not identity recognition; that remains fail-closed.
    implementation("com.google.mlkit:face-detection:16.1.7")
    // Official stable AndroidX release; keep all Media3 modules in lockstep.
    val media3Version = "1.11.1"
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-session:$media3Version")
    implementation("androidx.media3:media3-datasource-okhttp:$media3Version")
    implementation("com.squareup.okhttp3:okhttp:5.5.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:5.5.0")
    testImplementation("com.squareup.okhttp3:okhttp-tls:5.5.0")
    testImplementation("androidx.work:work-testing:2.12.0")
    testImplementation("org.robolectric:robolectric:4.17")
}
