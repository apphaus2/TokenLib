/*
 * TokenLib.kt
 * TokenLib (Android)
 *
 * The one-call bootstrap: a server whose SQLite database sits in the app's
 * no-backup files directory and whose cipher key lives in the Android
 * Keystore. If either cannot be opened the server still comes up (in memory,
 * plain cipher) so the app keeps running.
 */
package us.apphaus.tokenlib.android

import android.content.Context
import java.io.File
import us.apphaus.tokenlib.HttpTransport
import us.apphaus.tokenlib.HttpUrlConnectionTransport
import us.apphaus.tokenlib.InMemoryStore
import us.apphaus.tokenlib.PlainCipher
import us.apphaus.tokenlib.SQLiteStore
import us.apphaus.tokenlib.SecretCipher
import us.apphaus.tokenlib.TokenServer
import us.apphaus.tokenlib.TokenStore

object TokenLib {
    /** The database file and Keystore alias suffix from before the rename to TokenLib; see [standard]. */
    const val LEGACY_DATABASE = "tokenx.sqlite"
    const val LEGACY_KEY_SUFFIX = ".tokenx"

    /**
     * A server in the app's private storage: `noBackupFilesDir/tokenlib.sqlite` and the Keystore alias
     * `<appId>.tokenlib`, so two apps sharing a process never share a key. Data left under the TokenX names is
     * moved first: the database file is renamed, stored keys are re-encrypted with the new Keystore key, and
     * the old Keystore entry is removed once every key reads back, so a launch that cannot reach the Keystore
     * retries next time.
     */
    fun standard(context: Context, appId: String = context.packageName, transport: HttpTransport = HttpUrlConnectionTransport()): TokenServer {
        val app = context.applicationContext
        runCatching { SQLiteStore.moveDatabase(File(app.noBackupFilesDir, LEGACY_DATABASE), File(app.noBackupFilesDir, "tokenlib.sqlite")) }
        val store: TokenStore = runCatching { AndroidSqlDatabase.store(app) }.getOrElse { InMemoryStore() }
        val cipher: SecretCipher = runCatching { KeystoreCipher("$appId.tokenlib") as SecretCipher }.getOrElse { PlainCipher }
        val server = TokenServer(store, cipher, transport)
        if (cipher is KeystoreCipher) runCatching {
            val legacy = KeystoreCipher("$appId$LEGACY_KEY_SUFFIX")
            if (legacy.hasKey()) {
                server.reencryptKeys(legacy)
                if (server.keysReadable) legacy.deleteKey()
            }
        }
        return server
    }
}
