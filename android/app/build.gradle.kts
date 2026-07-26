import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// key.properties is gitignored and points at a keystore held outside the repo.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.cura.cura"
    compileSdk = flutter.compileSdkVersion
    // Highest NDK any plugin asks for: whisper_ggml needs 29, the rest need 27.
    ndkVersion = "29.0.13113456"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.cura.cura"
        // llama.cpp's prebuilt .so needs API 26+; also the plugin is arm64-only.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Declared only when key.properties exists, so a clone still configures.
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                // v3 allows key rotation if this key is ever compromised.
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug signing so a clone without the keystore builds.
            signingConfig = signingConfigs.getByName(
                if (keystorePropertiesFile.exists()) "release" else "debug",
            )
            // Keeps the llama.cpp JNI callbacks and quiets ML Kit R8 warnings.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Release ships arm64 only; llama.cpp has no other build. Debug keeps every ABI for
// the emulator. ndk.abiFilters does not work here, the Flutter plugin overwrites it.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            "lib/armeabi-v7a/**",
            "lib/x86/**",
            "lib/x86_64/**",
        )
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
