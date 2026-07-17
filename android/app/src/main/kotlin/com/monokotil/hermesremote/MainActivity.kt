package com.monokotil.hermesremote

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
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
