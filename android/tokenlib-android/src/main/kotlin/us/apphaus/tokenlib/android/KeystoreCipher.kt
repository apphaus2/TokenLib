/*
 * KeystoreCipher.kt
 * TokenLib (Android)
 *
 * AES-GCM at rest for API keys: the symmetric key lives in the Android
 * Keystore (never leaves the device), the ciphertext in the SQLite store.
 */
package us.apphaus.tokenlib.android

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import us.apphaus.tokenlib.SecretCipher
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class KeystoreCipher(private val alias: String = "us.apphaus.tokenlib.secret-key") : SecretCipher {
    private val keyStore: KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun key(): SecretKey {
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return generator.generateKey()
    }

    /** Whether the Keystore entry exists, without creating it (encrypting or decrypting creates it on first use). */
    fun hasKey(): Boolean = keyStore.containsAlias(alias)

    /** Removes the Keystore entry. Anything encrypted with it can no longer be read. */
    fun deleteKey() { if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias) }

    /** Output: 12-byte IV followed by the GCM ciphertext and tag. */
    override fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher.iv + cipher.doFinal(plaintext)
    }

    override fun decrypt(ciphertext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, ciphertext.copyOfRange(0, 12)))
        return cipher.doFinal(ciphertext.copyOfRange(12, ciphertext.size))
    }
}
