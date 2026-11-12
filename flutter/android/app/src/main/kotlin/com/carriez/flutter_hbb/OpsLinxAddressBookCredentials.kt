package com.carriez.flutter_hbb

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class OpsLinxAddressBookCredentials(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "opslinx-addressbook-session"))
    private val alias = "opslinx.addressbook.session.v1"
    private val tokenPattern = Regex("[A-Za-z0-9_-]{43}")

    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun read(): String? {
        val sealed = try {
            file.readFully()
        } catch (error: java.io.FileNotFoundException) {
            return null
        }
        require(sealed.size == 12 + 43 + 16)
        val key = requireNotNull(store().getKey(alias, null) as? SecretKey)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12))
        return cipher.doFinal(sealed, 12, sealed.size - 12).decodeToString()
            .also { require(tokenPattern.matches(it)) }
    }

    fun write(token: String) {
        require(tokenPattern.matches(token))
        val key = store().getKey(alias, null) as? SecretKey ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                init(KeyGenParameterSpec.Builder(alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build())
                generateKey()
            }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val sealed = cipher.iv + cipher.doFinal(token.encodeToByteArray())
        val output = file.startWrite()
        try {
            output.write(sealed)
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    fun delete() {
        store().deleteEntry(alias)
        file.delete()
    }
}
