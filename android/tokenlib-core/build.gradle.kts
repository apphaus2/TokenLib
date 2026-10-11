plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-library`
    `maven-publish`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
    withSourcesJar()
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    // JDBC is only used by JdbcSqlDatabase (desktop, tests); Android apps use tokenlib-android's database.
    testImplementation(libs.sqlite.jdbc)
    testImplementation(libs.junit)
}

publishing {
    publications { create<MavenPublication>("maven") { from(components["java"]); artifactId = "tokenlib-core" } }
}
