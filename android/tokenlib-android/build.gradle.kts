plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
}

android {
    namespace = "us.apphaus.tokenlib.android"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
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
    api(project(":tokenlib-core"))
    testImplementation(libs.junit)
}

afterEvaluate {
    publishing { publications { create<MavenPublication>("release") { from(components["release"]); artifactId = "tokenlib-android" } } }
}
