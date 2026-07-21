package com.monokotil.hermesremote

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.app.Activity
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val SOUND_REQUEST = 9121
        private const val PREFS = "agent_remote_notifications"
        private const val SOUND_URI = "done_sound_uri"
        private const val SOUND_NAME = "done_sound_name"
        private const val MAX_SOUND_BYTES = 50L * 1024L * 1024L
        private const val RUNTIME_PREFS = "agent_remote_runtime"
        private const val APP_FOREGROUND = "app_foreground"
    }
    private var pendingSessionId: String? = null
    private var monitorChannel: MethodChannel? = null
    private var pendingSoundResult: MethodChannel.Result? = null
    private var previewPlayer: MediaPlayer? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingSessionId = intent?.getStringExtra("session_id")
    }

    override fun onStart() {
        super.onStart()
        getSharedPreferences(RUNTIME_PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(APP_FOREGROUND, true)
            .apply()
    }

    override fun onStop() {
        getSharedPreferences(RUNTIME_PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(APP_FOREGROUND, false)
            .apply()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingSessionId = intent.getStringExtra("session_id")
        pendingSessionId?.let { monitorChannel?.invokeMethod("openSession", it) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SOUND_REQUEST) return
        val result = pendingSoundResult
        pendingSoundResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(null)
            return
        }
        try {
            result?.success(storeNotificationSound(uri))
        } catch (error: Exception) {
            result?.error("notification_sound", error.message ?: "File suara tidak dapat dipakai", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "agent_remote/clipboard",
        ).setMethodCallHandler { call, result ->
            if (call.method != "getImage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                result.success(readClipboardImage())
            } catch (error: Exception) {
                result.error("clipboard_image", error.message, null)
            }
        }
        monitorChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "agent_remote/monitor",
        ).also { channel -> channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9120)
                    }
                    result.success(null)
                }
                "consumeOpenSession" -> {
                    result.success(pendingSessionId)
                    pendingSessionId = null
                }
                "pickNotificationSound" -> {
                    if (pendingSoundResult != null) {
                        result.error("notification_sound", "Picker masih terbuka", null)
                    } else {
                        pendingSoundResult = result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }, SOUND_REQUEST)
                    }
                }
                "getNotificationSound" -> {
                    val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    val path = prefs.getString(SOUND_URI, "").orEmpty()
                    val name = prefs.getString(SOUND_NAME, "").orEmpty()
                    val file = storedSoundFile(path)
                    if (file == null) {
                        prefs.edit().remove(SOUND_URI).remove(SOUND_NAME).apply()
                        result.success(null)
                    } else {
                        result.success(mapOf("uri" to file.absolutePath, "name" to name))
                    }
                }
                "clearNotificationSound" -> {
                    val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    deleteStoredSound(prefs.getString(SOUND_URI, "").orEmpty())
                    prefs.edit().remove(SOUND_URI).remove(SOUND_NAME).apply()
                    previewPlayer?.release()
                    previewPlayer = null
                    result.success(null)
                }
                "previewNotificationSound" -> try {
                    previewNotificationSound()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("notification_sound", error.message ?: "Preview suara gagal", null)
                }
                "start" -> {
                    val serviceIntent = Intent(this, AgentMonitorService::class.java).apply {
                        action = AgentMonitorService.ACTION_START
                        putExtra("tasksUrl", call.argument<String>("tasksUrl"))
                        putExtra("stopUrl", call.argument<String>("stopUrl"))
                        putExtra("token", call.argument<String>("token"))
                        putExtra("sessionId", call.argument<String>("sessionId"))
                        putExtra("title", call.argument<String>("title"))
                        putExtra("agents", call.argument<String>("agents"))
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    result.success(null)
                }
                "startSync" -> {
                    val serviceIntent = Intent(this, AgentMonitorService::class.java).apply {
                        action = AgentMonitorService.ACTION_SYNC
                        putExtra("tasksUrl", call.argument<String>("tasksUrl"))
                        putExtra("token", call.argument<String>("token"))
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } }
    }

    override fun onDestroy() {
        previewPlayer?.release()
        previewPlayer = null
        super.onDestroy()
    }

    private fun storeNotificationSound(uri: Uri): Map<String, String> {
        var name = "Suara custom"
        var declaredSize = -1L
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) declaredSize = cursor.getLong(sizeIndex)
            }
        }
        if (name.isBlank()) name = "Suara custom"
        if (declaredSize > MAX_SOUND_BYTES) throw IllegalArgumentException("Ukuran suara maksimal 50 MB")
        val extension = safeSoundExtension(name)
        val directory = soundDirectory().apply { mkdirs() }
        val temporary = File.createTempFile("done-", ".$extension", directory)
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalArgumentException("File suara tidak dapat dibaca")
            input.use { source ->
                temporary.outputStream().use { target ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_SOUND_BYTES) throw IllegalArgumentException("Ukuran suara maksimal 50 MB")
                        target.write(buffer, 0, count)
                    }
                    if (total == 0L) throw IllegalArgumentException("File suara kosong")
                }
            }
            validateSoundFile(temporary)
            val target = File(directory, "done-${System.currentTimeMillis()}.$extension")
            if (!temporary.renameTo(target)) {
                temporary.copyTo(target, overwrite = true)
                temporary.delete()
            }
            val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val oldPath = prefs.getString(SOUND_URI, "").orEmpty()
            prefs.edit().putString(SOUND_URI, target.absolutePath).putString(SOUND_NAME, name).apply()
            deleteStoredSound(oldPath, target)
            return mapOf("uri" to target.absolutePath, "name" to name)
        } catch (error: Exception) {
            temporary.delete()
            throw error
        }
    }

    private fun safeSoundExtension(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
        return extension.takeIf { it.length in 1..10 && it.all(Char::isLetterOrDigit) } ?: "media"
    }

    private fun validateSoundFile(file: File) {
        val player = MediaPlayer()
        try {
            player.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build())
            player.setDataSource(file.absolutePath)
            player.prepare()
        } catch (_: Exception) {
            throw IllegalArgumentException("Format media tidak didukung oleh Android")
        } finally {
            player.release()
        }
    }

    private fun previewNotificationSound() {
        val path = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(SOUND_URI, "").orEmpty()
        val file = storedSoundFile(path) ?: throw IllegalStateException("Pilih suara custom terlebih dahulu")
        previewPlayer?.release()
        previewPlayer = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build())
            setDataSource(file.absolutePath)
            setOnCompletionListener { player ->
                player.release()
                if (previewPlayer === player) previewPlayer = null
            }
            setOnErrorListener { player, _, _ ->
                player.release()
                if (previewPlayer === player) previewPlayer = null
                true
            }
            prepare()
            start()
        }
    }

    private fun soundDirectory(): File = File(filesDir, "notification-sounds")

    private fun storedSoundFile(path: String): File? {
        if (path.isEmpty()) return null
        return try {
            val directory = soundDirectory().canonicalFile
            val file = File(path).canonicalFile
            file.takeIf { it.isFile && it.parentFile == directory }
        } catch (_: Exception) {
            null
        }
    }

    private fun deleteStoredSound(path: String, except: File? = null) {
        val file = storedSoundFile(path) ?: return
        if (except == null || file.absolutePath != except.absolutePath) file.delete()
    }

    private fun readClipboardImage(): Map<String, String>? {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val uri: Uri = clip.getItemAt(0).uri ?: return null
        val mimeType = contentResolver.getType(uri) ?: return null
        if (!mimeType.startsWith("image/")) return null
        val extension = mimeType.substringAfter('/', "png").substringBefore('+')
        val directory = File(cacheDir, "clipboard-images").apply { mkdirs() }
        val target = File(directory, "clipboard-${System.currentTimeMillis()}.$extension")
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        return mapOf(
            "path" to target.absolutePath,
            "name" to target.name,
            "mimeType" to mimeType,
        )
    }
}
