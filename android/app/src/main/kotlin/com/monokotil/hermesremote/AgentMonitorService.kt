package com.monokotil.hermesremote

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

class AgentMonitorService : Service() {
    companion object {
        const val ACTION_START = "agent_remote.START"
        const val ACTION_STOP = "agent_remote.STOP"
        const val ACTION_SYNC = "agent_remote.SYNC_CODEX"
        const val CHANNEL_RUNNING = "agent_remote_running"
        const val CHANNEL_DONE = "agent_remote_done"
        const val NOTIFICATION_ID = 9120
        const val SYNC_NOTIFICATION_ID = 9121
        const val SYNC_PREFS = "agent_remote_codex_sync"
    }

    private val monitoredSessions = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var syncActive = false
    @Volatile private var syncThreadRunning = false
    @Volatile private var syncTasksUrl = ""
    @Volatile private var syncToken = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val syncPreferences = getSharedPreferences(SYNC_PREFS, MODE_PRIVATE)
        if (intent == null || intent.action == ACTION_SYNC) {
            val tasksUrl = intent?.getStringExtra("tasksUrl")
                ?: syncPreferences.getString("tasksUrl", "")
                ?: ""
            val token = intent?.getStringExtra("token")
                ?: syncPreferences.getString("token", "")
                ?: ""
            if (tasksUrl.isEmpty()) return START_NOT_STICKY
            syncPreferences.edit()
                .putString("tasksUrl", tasksUrl)
                .putString("token", token)
                .apply()
            startCodexSync(tasksUrl, token)
            return START_STICKY
        }
        val sessionId = intent?.getStringExtra("sessionId") ?: return START_NOT_STICKY
        val tasksUrl = intent.getStringExtra("tasksUrl") ?: return START_NOT_STICKY
        val stopUrl = intent.getStringExtra("stopUrl") ?: return START_NOT_STICKY
        val token = intent.getStringExtra("token") ?: ""
        val title = intent.getStringExtra("title") ?: "Agent task"
        val agents = intent.getStringExtra("agents") ?: "Agent"
        createChannels()
        if (intent.action == ACTION_STOP) {
            thread { post(stopUrl, token) }
            monitoredSessions.remove(sessionId)
            getSystemService(NotificationManager::class.java).cancel(notificationId(sessionId))
            if (monitoredSessions.isEmpty() && !syncActive) stopSelf()
            return START_NOT_STICKY
        }
        val taskNotification = notification(
            title,
            "$agents - Menunggu proses...",
            sessionId,
            stopUrl,
            token,
            true,
        )
        if (syncActive) {
            notify(notificationId(sessionId), taskNotification)
        } else {
            startForeground(notificationId(sessionId), taskNotification)
        }
        if (monitoredSessions.add(sessionId)) {
            thread { monitor(tasksUrl, stopUrl, token, sessionId, title, agents) }
        }
        return START_NOT_STICKY
    }

    private fun monitor(
        tasksUrl: String,
        stopUrl: String,
        token: String,
        sessionId: String,
        fallbackTitle: String,
        fallbackAgents: String,
    ) {
        var seen = false
        var idlePolls = 0
        val monitorStartedAt = System.currentTimeMillis()
        while (monitoredSessions.contains(sessionId)) {
            try {
                val root = JSONObject(get(tasksUrl, token))
                val tasks = root.optJSONArray("tasks")
                var task: JSONObject? = null
                if (tasks != null) {
                    for (index in 0 until tasks.length()) {
                        val candidate = tasks.optJSONObject(index) ?: continue
                        if (candidate.optString("session_id") == sessionId) {
                            task = candidate
                            break
                        }
                    }
                }
                if (task != null) {
                    seen = true
                    val status = task.optString("status")
                    val title = task.optString("title", fallbackTitle)
                    val detail = task.optString("detail", "Agent sedang bekerja")
                    val agents = task.optJSONArray("agents")?.let { array ->
                        (0 until array.length()).joinToString(" + ") { array.optString(it) }
                    }.orEmpty().ifEmpty { fallbackAgents }
                    val elapsedSeconds = if (task.has("elapsedSeconds")) {
                        task.optLong("elapsedSeconds", 0L)
                    } else {
                        ((System.currentTimeMillis() - monitorStartedAt) / 1000).coerceAtLeast(0)
                    }
                    val elapsed = formatDuration(elapsedSeconds)
                    if (status == "running") {
                        idlePolls = 0
                        notify(
                            notificationId(sessionId),
                            notification(
                                title,
                                "$agents - $detail - $elapsed",
                                sessionId,
                                stopUrl,
                                token,
                                true,
                            ),
                        )
                    } else {
                        val success = status == "completed"
                        val changedFiles = task.optInt("changedFiles", 0)
                        val completionDetail = if (success && !detail.contains("file berubah")) {
                            "$detail - $changedFiles file berubah"
                        } else {
                            detail
                        }
                        val completionText = if (success) {
                            "$title - $completionDetail - $elapsed"
                        } else {
                            "$title - $detail - $elapsed"
                        }
                        notify(
                            notificationId(sessionId) + 10000,
                            notification(
                                if (success) "Task selesai" else "Task $status",
                                completionText,
                                sessionId,
                                stopUrl,
                                token,
                                false,
                            ),
                        )
                        break
                    }
                } else {
                    idlePolls++
                    if ((seen && idlePolls >= 4) || (!seen && idlePolls >= 20)) break
                }
            } catch (_: Exception) {
                idlePolls++
            }
            Thread.sleep(3000)
        }
        monitoredSessions.remove(sessionId)
        getSystemService(NotificationManager::class.java).cancel(notificationId(sessionId))
        if (monitoredSessions.isEmpty() && !syncActive) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun startCodexSync(tasksUrl: String, token: String) {
        createChannels()
        syncActive = true
        syncTasksUrl = tasksUrl
        syncToken = token
        startForeground(
            SYNC_NOTIFICATION_ID,
            notification(
                "Sinkron Codex aktif",
                "Menunggu task Codex PC selesai",
                "",
                "",
                token,
                true,
                false,
            ),
        )
        synchronized(this) {
            if (syncThreadRunning) return
            syncThreadRunning = true
        }
        thread {
            try {
                monitorCodexTasks()
            } finally {
                syncThreadRunning = false
            }
        }
    }

    private fun monitorCodexTasks() {
        val preferences = getSharedPreferences(SYNC_PREFS, MODE_PRIVATE)
        val seen = preferences.getStringSet("seenTasks", emptySet())?.toMutableSet()
            ?: mutableSetOf()
        var initialized = preferences.getBoolean("initialized", false)
        while (syncActive) {
            try {
                val tasks = JSONObject(get(syncTasksUrl, syncToken)).optJSONArray("tasks")
                if (tasks != null) {
                    for (index in 0 until tasks.length()) {
                        val task = tasks.optJSONObject(index) ?: continue
                        if (task.optString("source") != "codex_desktop") continue
                        if (task.optString("status") != "completed") continue
                        val taskId = task.optString("id")
                        if (taskId.isEmpty() || !seen.add(taskId)) continue
                        if (initialized) {
                            val title = task.optString("title", "Codex task")
                            val detail = task.optString("detail", "Task Codex selesai")
                            val elapsedSeconds = task.optLong("elapsedSeconds", 0L)
                            val notificationText = if (elapsedSeconds > 0) {
                                "$title - $detail - ${formatDuration(elapsedSeconds)}"
                            } else {
                                "$title - $detail"
                            }
                            notify(
                                externalNotificationId(taskId),
                                notification(
                                    "Codex task selesai",
                                    notificationText,
                                    "",
                                    "",
                                    syncToken,
                                    false,
                                    false,
                                ),
                            )
                        }
                    }
                    initialized = true
                    preferences.edit()
                        .putBoolean("initialized", true)
                        .putStringSet("seenTasks", seen.toList().takeLast(200).toSet())
                        .apply()
                }
            } catch (_: Exception) {
            }
            Thread.sleep(5000)
        }
    }

    private fun notification(
        title: String,
        text: String,
        sessionId: String,
        stopUrl: String,
        token: String,
        ongoing: Boolean,
        showStopAction: Boolean = ongoing,
    ): android.app.Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (sessionId.isNotEmpty()) putExtra("session_id", sessionId)
        }
        val openPending = PendingIntent.getActivity(
            this,
            sessionId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = android.app.Notification.Builder(
            this,
            if (ongoing) CHANNEL_RUNNING else CHANNEL_DONE,
        )
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(android.app.Notification.BigTextStyle().bigText(text))
            .setContentIntent(openPending)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(ongoing)
            .setAutoCancel(!ongoing)
        if (ongoing && showStopAction) {
            val stopIntent = Intent(this, AgentMonitorService::class.java).apply {
                action = ACTION_STOP
                putExtra("sessionId", sessionId)
                putExtra("tasksUrl", "")
                putExtra("stopUrl", stopUrl)
                putExtra("token", token)
            }
            val stopPending = PendingIntent.getService(
                this,
                sessionId.hashCode() + 1,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(android.R.drawable.ic_media_pause, "Stop", stopPending)
        }
        builder.addAction(android.R.drawable.ic_menu_view, "Buka", openPending)
        return builder.build()
    }

    private fun formatDuration(totalSeconds: Long): String {
        val safeSeconds = totalSeconds.coerceAtLeast(0)
        if (safeSeconds < 60) return "$safeSeconds detik"
        val minutes = safeSeconds / 60
        val seconds = safeSeconds % 60
        if (minutes < 60) {
            return if (seconds == 0L) "$minutes menit" else "$minutes menit $seconds detik"
        }
        val hours = minutes / 60
        val remainingMinutes = minutes % 60
        return if (remainingMinutes == 0L) "$hours jam" else "$hours jam $remainingMinutes menit"
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_RUNNING, "Task berjalan", NotificationManager.IMPORTANCE_LOW),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, "Task selesai", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    private fun notify(id: Int, notification: android.app.Notification) {
        getSystemService(NotificationManager::class.java).notify(id, notification)
    }

    private fun notificationId(sessionId: String): Int =
        1000 + (sessionId.hashCode() and 0x7fffffff) % 8000

    private fun externalNotificationId(taskId: String): Int =
        20000 + (taskId.hashCode() and 0x7fffffff) % 10000

    private fun get(url: String, token: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 8000
        connection.readTimeout = 8000
        if (token.isNotEmpty()) connection.setRequestProperty("Authorization", "Bearer $token")
        return connection.inputStream.bufferedReader().use { it.readText() }
    }

    private fun post(url: String, token: String) {
        if (url.isEmpty()) return
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        if (token.isNotEmpty()) connection.setRequestProperty("Authorization", "Bearer $token")
        connection.outputStream.use { it.write("{}".toByteArray()) }
        connection.inputStream.close()
    }
}
