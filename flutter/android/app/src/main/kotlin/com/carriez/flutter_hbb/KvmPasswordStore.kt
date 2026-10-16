package com.carriez.flutter_hbb

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object KvmPasswordStore {
    private const val alias = "io.dafacility.access.kvm-passwords"

    fun register(context: Context, messenger: BinaryMessenger) {
        val channel = MethodChannel(
            messenger, "io.dafacility.access/kvm-passwords",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()
        )
        channel.setMethodCallHandler { call, result ->
            val account = call.argument<String>("account")
            if (account.isNullOrEmpty()) {
                result.error("invalid_account", "Missing KVM account.", null)
                return@setMethodCallHandler
            }
            try {
                val name = MessageDigest.getInstance("SHA-256")
                    .digest(account.toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it) }
                val directory = File(context.noBackupFilesDir, "kvm-passwords")
                check(directory.isDirectory || directory.mkdirs())
                val file = AtomicFile(File(directory, name))
                when (call.method) {
                    "read" -> {
                        if (!file.baseFile.exists()) {
                            result.success(null)
                        } else {
                            val data = file.readFully()
                            require(data.size >= 28)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
                            cipher.updateAAD(account.toByteArray(Charsets.UTF_8))
                            result.success(String(cipher.doFinal(data.copyOfRange(12, data.size)), Charsets.UTF_8))
                        }
                    }
                    "write" -> {
                        val password = call.argument<String>("password")
                            ?: throw IllegalArgumentException("Missing password")
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, key())
                        cipher.updateAAD(account.toByteArray(Charsets.UTF_8))
                        val data = cipher.iv + cipher.doFinal(password.toByteArray(Charsets.UTF_8))
                        val output = file.startWrite()
                        try {
                            output.write(data)
                            file.finishWrite(output)
                        } catch (error: Exception) {
                            file.failWrite(output)
                            throw error
                        }
                        result.success(null)
                    }
                    "delete" -> {
                        file.delete()
                        check(!file.baseFile.exists())
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("keystore", "Could not access the saved KVM password.", null)
            }
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
            generateKey()
        }
    }
}
