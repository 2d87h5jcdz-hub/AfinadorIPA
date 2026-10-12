import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Assinatura: chave do repositório (android/keystore), ou outra via variáveis de ambiente.
val keystorePath = System.getenv("PESTANA_KEYSTORE") ?: "keystore/pestana-release.jks"
val keystorePass = System.getenv("PESTANA_KEYSTORE_PASSWORD") ?: "pestana123"
val keyAliasName = System.getenv("PESTANA_KEY_ALIAS") ?: "pestana"
val keyPass = System.getenv("PESTANA_KEY_PASSWORD") ?: "pestana123"

// No CI, cada execução gera um versionCode maior: o APK novo instala por cima do antigo.
val ciBuildNumber = System.getenv("GITHUB_RUN_NUMBER")?.toIntOrNull() ?: 1

android {
    namespace = "com.pestana.estudio"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.pestana.estudio"
        minSdk = 26
        targetSdk = 36
        versionCode = ciBuildNumber
        versionName = "0.2.0"

        // ONNX Runtime traz bibliotecas nativas: só as arquiteturas que importam (celulares + emulador).
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            storeFile = rootProject.file(keystorePath)
            storePassword = keystorePass
            keyAlias = keyAliasName
            keyPassword = keyPass
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.06.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    // Treino: Sonic (tom/velocidade) do Media3 e a IA de separação no ONNX Runtime
    implementation("androidx.media3:media3-common:1.5.1")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.20.0")

    testImplementation("junit:junit:4.13.2")
}
