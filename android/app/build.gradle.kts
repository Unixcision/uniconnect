plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.unixcision.uniconnect.android"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "com.unixcision.uniconnect.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        resourceConfigurations += "es"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Whisper on the phone is built for the one architecture every Android phone in use has;
        // a second copy for armeabi-v7a or x86_64 would double the native payload for emulators.
        ndk { abiFilters += "arm64-v8a" }
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    sourceSets["main"].res.srcDir(layout.buildDirectory.dir("generated/brand/res"))
}

// The canonical Mac artwork is reused byte-for-byte, not copied into another source of truth.
val syncBrandArtwork by tasks.registering(Copy::class) {
    from(rootProject.file("../design/UniConnect.icon/Assets/uniconnect-icon.png"))
    into(layout.buildDirectory.dir("generated/brand/res/drawable-nodpi"))
    rename { "uniconnect_mark.png" }
}
tasks.named("preBuild").configure { dependsOn(syncBrandArtwork) }

// Los ejemplos de `contracts/` SON el contrato, no una ilustración: las pruebas de Mac, Linux y
// Android leen los mismos ficheros. Copiarlos a los recursos de prueba es lo que impide que este
// lado se aleje del acordado sin que nadie se entere.
val syncContractFixtures by tasks.registering(Copy::class) {
    from(rootProject.file("../contracts/relaunch-v1"))
    into(layout.buildDirectory.dir("generated/contracts/relaunch-v1"))
    include("*.json")
}
android.sourceSets["test"].resources.srcDir(layout.buildDirectory.dir("generated/contracts"))
// El nombre exacto de la tarea de recursos de prueba depende de la variante, así que se engancha
// por tipo en vez de por nombre.
tasks.matching { it.name.startsWith("process") && it.name.endsWith("UnitTestJavaRes") }
    .configureEach { dependsOn(syncContractFixtures) }

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    // The stable BOM still ships Material 3 1.4; the expressive components (MaterialExpressiveTheme,
    // LoadingIndicator, MotionScheme) live in the 1.5 line, pinned explicitly.
    implementation("androidx.compose.material3:material3:1.5.0-alpha18")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.1")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.datastore:datastore-preferences:1.1.7")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    // Real JVM JSON for protocol fixtures; Android's local-unit-test android.jar contains stubs.
    testImplementation("org.json:json:20260814")
}
