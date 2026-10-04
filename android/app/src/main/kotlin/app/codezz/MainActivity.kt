package app.codezz

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val cryptoChannelName = "codezz/crypto"
    private var notifyChannel: MethodChannel? = null

    /** Payload of the notification that launched the app, until read. */
    private var launchPayload: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Device links embed the ZCode Web access token; they are stored
        // encrypted with a non-exportable Android Keystore key.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cryptoChannelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "encrypt" -> result.success(cryptoEncrypt(call.argument<String>("value") ?: ""))
                        "decrypt" -> result.success(cryptoDecrypt(call.argument<String>("value") ?: ""))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("crypto", e.message, null)
                }
            }

        notifyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codezz/notify").apply {
            setMethodCallHandler { call, result ->
                try {
                    handleNotify(call.method, call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                        .let { result.success(it) }
                } catch (e: Exception) {
                    result.error("notify", e.message, null)
                }
            }
        }
        launchPayload = intent?.getStringExtra(TaskNotifications.EXTRA_PAYLOAD)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(TaskNotifications.EXTRA_PAYLOAD)?.let { notifyChannel?.invokeMethod("open", it) }
    }

    private fun handleNotify(method: String, args: Map<*, *>): Any? {
        when (method) {
            "init" -> {
                TaskNotifications.ensureChannels(
                    this, args["runningChannel"] as? String ?: "Running", args["doneChannel"] as? String ?: "Finished"
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                }
                return launchPayload.also { launchPayload = null }
            }
            "progress" -> {
                TaskProgressService.latest = TaskNotifications.progress(
                    this,
                    args["title"] as? String ?: "",
                    args["text"] as? String ?: "",
                    (args["lines"] as? List<*>)?.map { "$it" } ?: emptyList(),
                    (args["progress"] as? Number)?.toInt(),
                    (args["max"] as? Number)?.toInt(),
                    args["payload"] as? String,
                )
                val nm = getSystemService(android.app.NotificationManager::class.java)
                if (TaskProgressService.running) {
                    // Same id: replaces the service's notification in place.
                    nm.notify(TaskNotifications.PROGRESS_ID, TaskProgressService.latest)
                    return null
                }
                try {
                    val service = Intent(this, TaskProgressService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service) else startService(service)
                } catch (e: Exception) {
                    // Not allowed from the background (Android 12+): a plain
                    // ongoing notification still shows the progress.
                    nm.notify(TaskNotifications.PROGRESS_ID, TaskProgressService.latest)
                }
            }
            "stopProgress" -> {
                TaskProgressService.latest = null
                stopService(Intent(this, TaskProgressService::class.java))
                getSystemService(android.app.NotificationManager::class.java).cancel(TaskNotifications.PROGRESS_ID)
            }
            "done" -> TaskNotifications.done(
                this,
                (args["id"] as? Number)?.toInt() ?: 2,
                args["title"] as? String ?: "",
                args["text"] as? String ?: "",
                args["payload"] as? String,
            )
            "cancel" -> getSystemService(android.app.NotificationManager::class.java)
                .cancel((args["id"] as? Number)?.toInt() ?: 0)
        }
        return null
    }

    private val keyAlias = "codezz_credentials"

    private fun getOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(keyAlias)) {
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(
                KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            return kg.generateKey()
        }
        return (ks.getEntry(keyAlias, null) as KeyStore.SecretKeyEntry).secretKey
    }

    /** AES/GCM: [12-byte IV][ciphertext+tag] -> base64. */
    private fun cryptoEncrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val cipherBytes = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val out = ByteArray(iv.size + cipherBytes.size)
        System.arraycopy(iv, 0, out, 0, iv.size)
        System.arraycopy(cipherBytes, 0, out, iv.size, cipherBytes.size)
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    private fun cryptoDecrypt(base64: String): String {
        val data = Base64.decode(base64, Base64.NO_WRAP)
        val iv = data.copyOfRange(0, 12)
        val cipherBytes = data.copyOfRange(12, data.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(cipherBytes), Charsets.UTF_8)
    }
}
