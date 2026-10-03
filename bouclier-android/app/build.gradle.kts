import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val appVersionName = "1.1.0"

android {
    namespace = "io.github.aaronjones56.bouclier"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.aaronjones56.bouclier"
        minSdk = 26
        targetSdk = 36
        versionCode = 2
        versionName = appVersionName
    }

    signingConfigs {
        // Clé versionnée avec le projet (mots de passe publics, comme la clé « debug »
        // d'Android) : chaque compilation, locale ou sur GitHub Actions, signe l'APK
        // avec la même clé, et les mises à jour s'installent par-dessus l'ancienne
        // version. Pour une publication sur un store, utilisez votre propre clé.
        create("shared") {
            storeFile = file("bouclier.keystore")
            storePassword = "android"
            keyAlias = "bouclier"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("shared")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("shared")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    testOptions {
        // Robolectric : les tests d'interface ont besoin des ressources de l'application.
        unitTests.isIncludeAndroidResources = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

// Fichier produit : Bouclier-<version>-release.apk
base.archivesName.set("Bouclier-$appVersionName")

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.webkit)
    implementation(libs.kotlinx.coroutines.android)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(platform(libs.androidx.compose.bom))
    testImplementation(libs.androidx.compose.ui.test.junit4)
}
