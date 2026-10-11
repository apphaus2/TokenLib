// Root build for the TokenLib libraries.
//
//   tokenlib-core     pure Kotlin/JVM: catalog, profiles, providers over HTTP, repositories, server, client
//   tokenlib-android  Android: SQLite database adapter, the Keystore cipher and the TokenLib.standard bootstrap
//   tokenlib-compose  Compose: TokenLibModel plus the settings, usage and status composables a host app embeds
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.compose.compiler) apply false
}

allprojects {
    group = "us.apphaus.tokenlib"
    version = "1.0.0"
}
