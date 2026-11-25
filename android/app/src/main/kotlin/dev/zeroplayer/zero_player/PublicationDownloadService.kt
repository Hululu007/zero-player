package dev.zeroplayer.zero_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.StatFs
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal object PublicationAndroidBridge {
    private val taskId = Regex("[a-f0-9]{64}")

    fun installStorage(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "zero_player/publications_storage").setMethodCallHandler { call, result ->
            if (call.method != "free") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val path = appPath(context, call.arguments as String)
                result.success(StatFs(path.path).availableBytes)
            } catch (_: Exception) {
                result.error("storage", "无法核对图书存储空间", null)
            }
        }
    }

    fun installActivity(context: Context, messenger: BinaryMessenger) {
        installStorage(context, messenger)
        MethodChannel(messenger, "zero_player/publications_worker").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        val id = requireNotNull(call.argument<String>("id"))
                        require(taskId.matches(id))
                        val root = appPath(context, requireNotNull(call.argument<String>("root")))
                        val command = Intent(context, PublicationDownloadService::class.java)
                            .setAction(PublicationDownloadService.START)
                            .putExtra("root", root.path).putExtra("id", id)
                            .putExtra("code", call.argument<String>("code")?.take(256))
                            .putExtra("codeFor", call.argument<String>("codeFor")?.takeIf(taskId::matches))
                            .putExtra("baiduAccessToken", call.argument<String>("baiduAccessToken")?.take(512))
                        ContextCompat.startForegroundService(context, command)
                        result.success(null)
                    } catch (_: IllegalStateException) {
                        result.error("system_wait", "系统暂未允许启动图书下载", null)
                    } catch (_: Exception) {
                        result.error("storage", "无法启动图书下载", null)
                    }
                }
                "pause", "recheck" -> {
                    val service = PublicationDownloadService.current
                    if (service == null && call.method == "pause") {
                        result.error("worker_unavailable", "后台下载服务已停止", null)
                    } else if (service == null) result.success(null)
                    else service.command(call.method, call.arguments, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun appPath(context: Context, path: String): File {
        val parent = File(context.applicationInfo.dataDir).canonicalFile
        val file = File(path).canonicalFile
        require(file.path.startsWith(parent.path + File.separator))
        return file
    }
}

class PublicationDownloadService : Service() {
    companion object {
        const val START = "zero_player.publications.START"
        private const val PAUSE = "zero_player.publications.PAUSE"
        private const val CHANNEL = "publication_downloads"
        private const val NOTICE = 3821
        internal var current: PublicationDownloadService? = null
            private set
    }

    private val main = Handler(Looper.getMainLooper())
    private val queued = ArrayDeque<Map<String, String?>>()
    private var root: String? = null
    private var engine: FlutterEngine? = null
    private var bridge: MethodChannel? = null
    private var ready = false
    private var stopping = false
    private var timedOut = false
    private var requests = 0L
    private val manager by lazy { getSystemService(NotificationManager::class.java) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE) {
            command("pause", mapOf("id" to intent.getStringExtra("id"),
                "generation" to intent.getIntExtra("generation", -1)))
            return START_NOT_STICKY
        }
        if (intent?.action != START) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (timedOut) return START_NOT_STICKY
        try {
            val directory = PublicationAndroidBridge.appPath(this, requireNotNull(intent.getStringExtra("root")))
            check(root == null || root == directory.path)
            root = directory.path
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL, "图书下载", NotificationManager.IMPORTANCE_LOW))
            }
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTICE, notification(emptyList()), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTICE, notification(emptyList()))
            }
            current = this
            requests++
            queued.add(mapOf(
                "id" to intent.getStringExtra("id"),
                "code" to intent.getStringExtra("code"),
                "codeFor" to intent.getStringExtra("codeFor"),
                "baiduAccessToken" to intent.getStringExtra("baiduAccessToken")
            ))
            if (engine == null) startEngine()
            flush()
        } catch (_: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startEngine() {
        val worker = FlutterEngine(applicationContext, null, false)
        engine = worker
        val messenger = worker.dartExecutor.binaryMessenger
        PublicationAndroidBridge.installStorage(this, messenger)
        bridge = MethodChannel(messenger, "zero_player/publications_engine").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "root" -> result.success(root)
                    "isMetered" -> result.success(getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered ?: true)
                    "ready" -> {
                        ready = true
                        result.success(null)
                        flush()
                    }
                    "progress" -> {
                        val tasks = call.argument<List<Map<String, Any?>>>("tasks").orEmpty()
                        result.success(null)
                        if (!stopping) {
                            manager.notify(NOTICE, notification(tasks))
                            if (call.argument<Boolean>("busy") != true && queued.isEmpty()) {
                                main.postDelayed({ if (!stopping && ready) confirmIdle() }, 500)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        val bundle = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        worker.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(bundle, "publicationBackgroundMain"))
        main.postDelayed({ if (engine === worker && !ready) stopSelf() }, 20_000)
    }

    private fun flush() {
        if (!ready || stopping) return
        while (queued.isNotEmpty()) command("start", queued.removeFirst())
    }

    private fun confirmIdle() {
        val before = requests
        bridge?.invokeMethod("idle", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (result == true && requests == before && queued.isEmpty() && !stopping) {
                    stopping = true
                    command("stop", null, object : MethodChannel.Result {
                        override fun success(result: Any?) = finishIdle()
                        override fun error(code: String, message: String?, details: Any?) = finishIdle()
                        override fun notImplemented() = finishIdle()
                    })
                }
            }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    private fun finishIdle() {
        if (timedOut || queued.isEmpty()) {
            stopSelf()
            return
        }
        disposeEngine()
        stopping = false
        startEngine()
    }

    private fun disposeEngine() {
        ready = false
        bridge?.setMethodCallHandler(null)
        bridge = null
        engine?.destroy()
        engine = null
    }

    internal fun command(method: String, args: Any?, result: MethodChannel.Result? = null) {
        val channel = bridge
        if (!ready || channel == null) {
            if (method == "pause") result?.error("worker_starting", "后台下载服务尚未就绪", null)
            else result?.success(null)
            return
        }
        channel.invokeMethod(method, args, result)
    }

    private fun notification(tasks: List<Map<String, Any?>>): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        builder.setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("图书下载").setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        val running = tasks.filter { it["state"] == "resolving" || it["state"] == "downloading" }
        val progress = if (running.isEmpty()) {
            tasks.firstOrNull()?.get("status") as? String ?: "正在准备下载"
        } else {
            running.mapIndexed { index, task ->
                val received = (task["received"] as? Number)?.toLong() ?: 0L
                val total = (task["total"] as? Number)?.toLong() ?: 0L
                val status = if (total > 0L) "${((received * 100) / total).coerceIn(0, 100)}%"
                    else task["status"] as? String ?: "正在准备"
                "任务 ${index + 1} · $status"
            }.joinToString("  ")
        }
        val paused = tasks.count { it["state"] == "paused" }
        val failed = tasks.count { it["state"] == "failed" }
        val summary = buildList {
            add(progress)
            if (running.isNotEmpty() && paused > 0) add("已暂停 $paused 个")
            if (running.isNotEmpty() && failed > 0) add("失败 $failed 个")
        }.joinToString(" · ")
        builder.setContentText(summary).setStyle(Notification.BigTextStyle().bigText(summary))
        if (running.isNotEmpty() || tasks.isEmpty()) builder.setProgress(0, 0, true)
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            builder.setContentIntent(PendingIntent.getActivity(this, NOTICE, it, PendingIntent.FLAG_IMMUTABLE))
        }
        for ((index, task) in running.take(2).withIndex()) {
            val id = task["id"] as? String ?: continue
            val generation = (task["generation"] as? Number)?.toInt() ?: continue
            val pause = Intent(this, PublicationDownloadService::class.java).setAction(PAUSE)
                .putExtra("id", id).putExtra("generation", generation)
                .setData(android.net.Uri.parse("publication-pause://$id/$generation"))
            val action = PendingIntent.getService(this, NOTICE, pause, PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, "暂停任务 ${index + 1}", action).build())
        }
        return builder.build()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        timedOut = true
        stopping = true
        command("timeout", null, object : MethodChannel.Result {
            override fun success(result: Any?) { stopSelf() }
            override fun error(code: String, message: String?, details: Any?) { stopSelf() }
            override fun notImplemented() { stopSelf() }
        })
        main.postDelayed({ stopSelf() }, 1250)
    }

    override fun onDestroy() {
        if (current === this) current = null
        main.removeCallbacksAndMessages(null)
        disposeEngine()
        queued.clear()
        super.onDestroy()
    }
}
