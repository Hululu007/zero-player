@file:Suppress("DEPRECATION")

package dev.zeroplayer.zero_player

import android.annotation.TargetApi
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricPrompt
import android.hardware.fingerprint.FingerprintManager
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android fingerprint confirmation plus a Keystore key that wraps the private
 * shelf data key. The data key never reaches Dart without a biometric prompt.
 *
 * Uses the platform BiometricPrompt (API 28+) so no extra Maven dependency is
 * required; Android 26-27 devices fall back to the vault password.
 */
@Suppress("DEPRECATION")
class VaultBiometric(private val activity: MainActivity) {
    companion object {
        const val CHANNEL = "zero_player/vault_biometric"
        private const val ALIAS = "zero_player_vault_biometric"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128
    }

    private var generation = 0L
    private var pendingResult: MethodChannel.Result? = null
    private var pendingMode: String? = null
    private var pendingPayload: String? = null
    private var prompt: VaultBiometricPrompt? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "available") {
            result.success(canAuthenticate())
            return
        }
        if (call.method != "wrap" && call.method != "unwrap") {
            result.notImplemented()
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.error("unavailable", "系统版本过低，请使用密码解锁", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "指纹验证正在进行", null)
            return
        }
        val payload = if (call.method == "wrap") {
            call.argument<String>("key")
        } else {
            call.argument<String>("payload")
        }
        if (payload.isNullOrEmpty()) {
            result.error("invalid", "缺少私密书架数据", null)
            return
        }
        // Registered before any Keystore work so a failure below can answer the
        // pending Dart call instead of leaving it unresolved.
        val attempt = ++generation
        pendingResult = result
        pendingMode = call.method
        pendingPayload = payload
        try {
            val cipher = if (call.method == "wrap") {
                encryptCipher()
            } else {
                decryptCipher(payload)
            }
            val subtitle = if (call.method == "wrap") "验证指纹以启用快速解锁" else "验证指纹以解锁"
            val active = VaultBiometricPrompt(
                activity,
                onSuccess = { authenticated ->
                    if (attempt == generation) complete(authenticated)
                },
                onError = { code, message ->
                    if (attempt == generation) finish(error = code, message = message)
                },
            )
            prompt = active
            active.authenticate(cipher, subtitle)
        } catch (_: KeyPermanentlyInvalidatedException) {
            finish(error = "invalidated", message = "指纹信息已变更")
        } catch (_: UnsupportedOperationException) {
            finish(error = "unavailable", message = "设备不支持指纹验证")
        } catch (_: Exception) {
            finish(error = "unavailable", message = "设备指纹不可用")
        }
    }

    fun canAuthenticate(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val fingerprint = activity.getSystemService(FingerprintManager::class.java)
        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        return fingerprint != null &&
            fingerprint.isHardwareDetected &&
            fingerprint.hasEnrolledFingerprints() &&
            keyguard?.isDeviceSecure == true
    }

    private fun keyStore(): KeyStore =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun existingKey(): SecretKey? =
        keyStore().getKey(ALIAS, null) as? SecretKey

    private fun createKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val builder = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun encryptCipher(): Cipher {
        var key = existingKey()
        if (key == null) key = createKey()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        try {
            cipher.init(Cipher.ENCRYPT_MODE, key)
        } catch (_: KeyPermanentlyInvalidatedException) {
            keyStore().deleteEntry(ALIAS)
            cipher.init(Cipher.ENCRYPT_MODE, createKey())
        }
        return cipher
    }

    private fun decryptCipher(payload: String): Cipher {
        val raw = Base64.decode(payload, Base64.NO_WRAP)
        require(raw.size > 2) { "payload" }
        val ivLength = raw[0].toInt() and 0xFF
        require(ivLength in 12..16 && raw.size > ivLength + 1) { "payload" }
        val iv = raw.copyOfRange(1, 1 + ivLength)
        val key = existingKey() ?: throw KeyPermanentlyInvalidatedException()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
        return cipher
    }

    private fun complete(cipher: Cipher) {
        val mode = pendingMode
        val payload = pendingPayload
        if (mode == null || payload == null) return
        try {
            if (mode == "wrap") {
                val clear = Base64.decode(payload, Base64.NO_WRAP)
                val encrypted = cipher.doFinal(clear)
                val iv = cipher.iv
                val combined = ByteArray(1 + iv.size + encrypted.size)
                combined[0] = iv.size.toByte()
                System.arraycopy(iv, 0, combined, 1, iv.size)
                System.arraycopy(encrypted, 0, combined, 1 + iv.size, encrypted.size)
                finish(value = Base64.encodeToString(combined, Base64.NO_WRAP))
            } else {
                val raw = Base64.decode(payload, Base64.NO_WRAP)
                val ivLength = raw[0].toInt() and 0xFF
                val cipherText = raw.copyOfRange(1 + ivLength, raw.size)
                val clear = cipher.doFinal(cipherText)
                finish(value = Base64.encodeToString(clear, Base64.NO_WRAP))
            }
        } catch (_: KeyPermanentlyInvalidatedException) {
            finish(error = "invalidated", message = "指纹信息已变更")
        } catch (_: Exception) {
            finish(error = "failed", message = "指纹解锁失败")
        }
    }

    private fun finish(value: String? = null, error: String? = null, message: String? = null) {
        val result = pendingResult ?: return
        generation++
        pendingResult = null
        pendingMode = null
        pendingPayload = null
        prompt = null
        if (error == null) result.success(value)
        else result.error(error, message, null)
    }

    fun close() {
        generation++
        val active = prompt
        prompt = null
        active?.cancel()
        pendingResult?.error("cancelled", "指纹验证已取消", null)
        pendingResult = null
        pendingMode = null
        pendingPayload = null
    }
}

/** Platform BiometricPrompt wrapper kept separate so API 26-27 can load safely. */
@TargetApi(Build.VERSION_CODES.P)
private class VaultBiometricPrompt(
    private val activity: MainActivity,
    private val onSuccess: (Cipher) -> Unit,
    private val onError: (String, String) -> Unit,
) {
    private var cancellation: CancellationSignal? = null

    fun authenticate(cipher: Cipher, subtitle: String) {
        val executor = activity.mainExecutor
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val authenticated = result.cryptoObject?.cipher
                if (authenticated == null) onError("failed", "缺少指纹验证凭据")
                else onSuccess(authenticated)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                val code = when (errorCode) {
                    BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                    BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                    13 -> "cancelled"
                    else -> "failed"
                }
                onError(code, errString.toString())
            }
        }
        val built = BiometricPrompt.Builder(activity)
            .setTitle("私密书架")
            .setSubtitle(subtitle)
            .setNegativeButton("使用密码", executor) { _, _ ->
                onError("cancelled", "已取消指纹验证")
            }
            .build()
        val signal = CancellationSignal()
        cancellation = signal
        built.authenticate(BiometricPrompt.CryptoObject(cipher), signal, executor, callback)
    }

    fun cancel() {
        cancellation?.cancel()
        cancellation = null
    }
}
