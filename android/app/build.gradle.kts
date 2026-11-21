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
        minSdk = 24
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
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
}

dependencies {
    // on-device text recognition (Latin), bundled in the app: no screen image ever leaves the phone
    implementation("com.google.mlkit:text-recognition:16.0.1")
}
