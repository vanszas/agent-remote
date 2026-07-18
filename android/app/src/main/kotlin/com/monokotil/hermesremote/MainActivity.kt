package com.monokotil.hermesremote

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingSessionId: String? = null
    private var monitorChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingSessionId = intent?.getStringExtra("session_id")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingSessionId = intent.getStringExtra("session_id")
        pendingSessionId?.let { monitorChannel?.invokeMethod("openSession", it) }
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
