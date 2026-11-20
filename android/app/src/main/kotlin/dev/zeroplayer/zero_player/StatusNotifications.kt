package dev.zeroplayer.zero_player

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class StatusNotifications(
    private val activity: Activity,
    private val channel: MethodChannel
) : AutoCloseable {
    private val manager = activity.getSystemService(NotificationManager::class.java)
    private val toggleAction = "${activity.packageName}.NOTIFICATION_TOGGLE_MUSIC"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == toggleAction) channel.invokeMethod("toggleMusic", null)
        }
    }

    init {
        ContextCompat.registerReceiver(
            activity, receiver, IntentFilter(toggleAction), ContextCompat.RECEIVER_NOT_EXPORTED
        )
        manager.createNotificationChannel(
            NotificationChannel("book_downloads", "书籍下载进度", NotificationManager.IMPORTANCE_LOW)
        )
        manager.createNotificationChannel(
            NotificationChannel("music_playback", "音乐播放", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun allowed() = manager.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "request" -> {
                val prefs = activity.getSharedPreferences("status_notifications", Context.MODE_PRIVATE)
                val firstRequest = !prefs.getBoolean("requested", false)
                if (Build.VERSION.SDK_INT >= 33 && !allowed() &&
                    (firstRequest || activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))
                ) {
                    prefs.edit().putBoolean("requested", true).apply()
                    activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION)
                } else {
                    activity.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
                }
            }
            "downloads" -> updateDownloads(call)
            "music" -> updateMusic(call)
            else -> { result.notImplemented(); return }
        }
        result.success(null)
    }

    private fun builder(channelId: String): Notification.Builder {
        val launch = Intent(activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return Notification.Builder(activity, channelId)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setContentIntent(PendingIntent.getActivity(activity, 0, launch, PendingIntent.FLAG_IMMUTABLE))
    }

    private fun updateDownloads(call: MethodCall) {
        val count = call.argument<Int>("count") ?: 0
        if (!allowed() || count == 0) {
            manager.cancel(DOWNLOADS)
            return
        }
        val total = call.argument<Int>("total") ?: 0
        val finished = call.argument<Int>("finished") ?: 0
        manager.notify(DOWNLOADS, builder("book_downloads")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("书籍下载")
            .setContentText(if (total > 0) "$count 项任务 · $finished/$total 章" else "$count 项任务 · 正在准备")
            .setProgress(total, finished, total == 0)
            .setOngoing(true)
            .build())
    }

    private fun updateMusic(call: MethodCall) {
        if (!allowed() || call.argument<Boolean>("active") != true) {
            manager.cancel(MUSIC)
            return
        }
        val playing = call.argument<Boolean>("playing") == true
        val loading = call.argument<Boolean>("loading") == true
        val notification = builder("music_playback")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("音乐播放")
            .setContentText(if (loading) "加载中" else if (playing) "正在播放" else "已暂停")
            .setOngoing(playing || loading)
        if (!loading) {
            val toggle = PendingIntent.getBroadcast(
                activity, 0, Intent(toggleAction).setPackage(activity.packageName), PendingIntent.FLAG_IMMUTABLE
            )
            val icon = if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
            notification.addAction(Notification.Action.Builder(icon, if (playing) "暂停" else "播放", toggle).build())
        }
        manager.notify(MUSIC, notification.build())
    }

    override fun close() {
        activity.unregisterReceiver(receiver)
        manager.cancel(DOWNLOADS)
        manager.cancel(MUSIC)
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val PERMISSION = 7250
        private const val DOWNLOADS = 401
        private const val MUSIC = 402
    }
}
