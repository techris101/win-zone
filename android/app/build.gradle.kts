plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.winzone.player"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    defaultConfig {
        applicationId = "app.winzone.player"
        minSdk = 21   // Android 5.0: the first version that allows screen recording by apps
        targetSdk = 35
        versionCode = 10
        versionName = "0.5.2"
        // phones only (ARM); leaves out emulator code and keeps the download small
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }
    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    // on-device text recognition (Latin), bundled in the app: no screen image ever leaves the phone
    implementation("com.google.mlkit:text-recognition:16.0.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")   // real JSON in tests (Android's copy only exists on phones)
}
