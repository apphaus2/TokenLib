plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.compose.compiler)
    `maven-publish`
}

android {
    namespace = "us.apphaus.tokenlib.compose"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    publishing { singleVariant("release") { withSourcesJar() } }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    api(project(":tokenlib-android"))
    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    implementation(libs.compose.runtime)
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    testImplementation(libs.junit)
}

afterEvaluate {
    publishing { publications { create<MavenPublication>("release") { from(components["release"]); artifactId = "tokenlib-compose" } } }
}
