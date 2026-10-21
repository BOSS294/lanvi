// Purpose: Store Groq/Sarvam API keys encrypted with an Android Keystore AES-GCM key.
// Integration: Used only by MainActivity and Jenny's background SMS automation.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Per-device encrypted provider secrets; no plaintext key stored in SharedPreferences.

package com.example.lanvi.jenny

import android.content.Context
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

internal class JennyKeyVault(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("lanvi_jenny_vault", Context.MODE_PRIVATE)
    private val aliasPrefix = "lanvi.jenny.key."

    @Synchronized
    fun put(provider: String, secret: String) {
        require(provider == "groq" || provider == "sarvam") { "Unsupported secret provider" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(provider))
        val encrypted = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        val stored = ByteArray(cipher.iv.size + encrypted.size)
        System.arraycopy(cipher.iv, 0, stored, 0, cipher.iv.size)
        System.arraycopy(encrypted, 0, stored, cipher.iv.size, encrypted.size)
        prefs.edit().putString("secret.$provider", Base64.encodeToString(stored, Base64.NO_WRAP)).apply()
    }

    @Synchronized
    fun get(provider: String): String? {
        if (provider != "groq" && provider != "sarvam") return null
        val encoded = prefs.getString("secret.$provider", null) ?: return null
        return try {
            val stored = Base64.decode(encoded, Base64.NO_WRAP)
            if (stored.size <= 12) return null
            val iv = stored.copyOfRange(0, 12)
            val ciphertext = stored.copyOfRange(12, stored.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(provider), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    @Synchronized
    fun delete(provider: String) {
        if (provider != "groq" && provider != "sarvam") return
        prefs.edit().remove("secret.$provider").apply()
        try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            keyStore.deleteEntry(aliasPrefix + provider)
        } catch (_: Exception) {
            // Secret is removed from the encrypted preference even if key cleanup fails.
        }
    }

    fun has(provider: String): Boolean = get(provider)?.isNotBlank() == true

    private fun getOrCreateKey(provider: String): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = aliasPrefix + provider
        val existing = keyStore.getKey(alias, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }
}
