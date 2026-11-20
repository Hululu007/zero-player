package dev.zeroplayer.zero_player

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Rational
import android.content.Intent
import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.File

class MainActivity : FlutterActivity() {
    private val videoPicker by lazy { VideoFilePicker(this) }
    private val videoDirectories by lazy { VideoDirectoryBridge(this) }
    private val playbackDiagnostics by lazy { PlaybackDeviceDiagnostics(this) }
    private val musicOverlay by lazy { MusicLyricsOverlay(this) }
    private val protectedBookExport by lazy { ProtectedBookExport(this) }
    private val vaultBiometric by lazy { VaultBiometric(this) }
    private var statusChannel: MethodChannel? = null
    private var statusNotifications: StatusNotifications? = null
    private var saveResult: MethodChannel.Result? = null
    private var savePath: String? = null
    private var exportCopy: ExportCopy? = null

    private class ExportCopy {
        @Volatile var cancelled = false
            private set
        private var settled = false

        @Synchronized
        fun cancel() {
            if (!settled) cancelled = true
        }

        @Synchronized
        fun settle(): Boolean {
            settled = true
            return !cancelled
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val status = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zero_player/status_notifications")
        statusChannel = status
        statusNotifications?.close()
        statusNotifications = StatusNotifications(this, status).also { bridge ->
            status.setMethodCallHandler(bridge::handle)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zero_player/reader_fonts")
            .setMethodCallHandler { call, result ->
                if (call.method == "systemFamilies") result.success(ReaderFonts.systemFamilies())
                else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VaultBiometric.CHANNEL)
            .setMethodCallHandler { call, result -> vaultBiometric.handle(call, result) }
        ActivityRequestCodes.validate()
        videoPicker.progress = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zero_player/local_video_progress")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zero_player/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setReaderImmersive" -> {
                        val controller = WindowCompat.getInsetsController(window, window.decorView)
                        val bars = WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars()
                        if (call.arguments == true) {
                            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                            controller.hide(bars)
                        } else {
                            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
                            controller.show(bars)
                        }
                        result.success(null)
                    }
                    "playbackDeviceDiagnostics" -> result.success(playbackDiagnostics.snapshot())
                    "musicOverlayPermission" -> result.success(musicOverlay.hasPermission())
                    "requestMusicOverlayPermission" -> {
                        musicOverlay.openPermissionSettings()
                        result.success(null)
                    }
                    "updateMusicOverlay" -> result.success(musicOverlay.update(call))
                    "hideMusicOverlay" -> { musicOverlay.hide(); result.success(null) }
                    "setPlayerOrientation" -> {
                        val orientation = when (call.argument<String>("mode")) {
                            "system" -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                            "auto" -> ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                            "locked" -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
                            else -> null
                        }
                        if (orientation == null) result.error("invalid_orientation", "Unknown orientation mode", null)
                        else {
                            requestedOrientation = orientation
                            result.success(null)
                        }
                    }
                    "saveFile" -> requestSave(call, result)
                    "chooseProtectedBookExport" -> protectedBookExport.choose(call, result)
                    "writeProtectedBookExport" -> protectedBookExport.write(call, result)
                    "cancelProtectedBookExport" -> protectedBookExport.cancel(call, result)
                    "finishProtectedBookExport" -> protectedBookExport.finish(call, result)
                    "chooseLocalVideo" -> videoPicker.choose(call, result)
                    "cancelLocalVideo" -> { videoPicker.cancel(); result.success(null) }
                    "clearLocalVideoCopies" -> videoPicker.clear(call, result)
                    "chooseVideoDirectory" -> videoDirectories.choose(result)
                    "verifyVideoInDirectory" -> videoDirectories.verify(call, result)
                    "saveVideoToDirectory" -> videoDirectories.save(call, result)
                    "cancelVideoSave" -> { videoDirectories.cancel(call.argument<String>("path")); result.success(null) }
                    "isTelevision" -> {
                        val mode = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        result.success(mode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
                    }
                    "isMetered" -> {
                        val network = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        result.success(network.isActiveNetworkMetered)
                    }
                    "pictureInPicture" -> {
                        try {
                            val params = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()
                            result.success(enterPictureInPictureMode(params))
                        } catch (_: Exception) { result.success(false) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == StatusNotifications.PERMISSION) {
            statusChannel?.invokeMethod("refresh", null)
        }
    }

    override fun onTrimMemory(level: Int) {
        playbackDiagnostics.lastTrimLevel = level
        super.onTrimMemory(level)
    }

    private fun requestSave(call: MethodCall, result: MethodChannel.Result) {
        if (saveResult != null) {
            result.error("busy", "A save dialog is already open", null)
            return
        }
        val path = call.argument<String>("path")
        if (path == null || !File(path).isFile) {
            result.error("invalid_file", "The export file does not exist", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = call.argument<String>("mime") ?: "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
            }
            saveResult = result
            savePath = path
            startActivityForResult(intent, ActivityRequestCodes.SAVE_FILE)
        } catch (_: Exception) {
            if (saveResult === result) {
                finishSave(result, error = "Unable to open the file picker")
            } else {
                result.error("save_failed", "Unable to prepare the file picker", null)
            }
        }
    }

    private fun finishSave(pending: MethodChannel.Result, saved: Boolean = false, error: String? = null) {
        if (saveResult !== pending) return
        saveResult = null
        savePath = null
        exportCopy = null
        if (error == null) pending.success(saved)
        else pending.error("save_failed", error, null)
    }

    override fun onDestroy() {
        try {
            exportCopy?.cancel() ?: saveResult?.let { finishSave(it) }
            statusNotifications?.close()
            statusNotifications = null
            statusChannel = null
            videoPicker.close()
            videoDirectories.close()
            musicOverlay.hide()
            protectedBookExport.close()
            vaultBiometric.close()
        } finally {
            super.onDestroy()
        }
    }

    @Deprecated("Uses the activity result bridge for Flutter file export")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (videoPicker.onResult(requestCode, resultCode, data)) return
        if (videoDirectories.onResult(requestCode, resultCode, data)) return
        if (protectedBookExport.onResult(requestCode, resultCode, data)) return
        if (requestCode != ActivityRequestCodes.SAVE_FILE) return
        val pending = saveResult ?: return
        val path = savePath
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || path == null) {
            finishSave(pending)
            return
        }
        if (exportCopy != null) return
        val copy = ExportCopy()
        exportCopy = copy
        Thread { copyExport(copy, pending, File(path), uri) }.start()
    }

    private fun copyExport(
        copy: ExportCopy, pending: MethodChannel.Result, source: File, target: Uri
    ) {
        var written = false
        try {
            if (!copy.cancelled) {
                source.inputStream().use { input ->
                    requireNotNull(contentResolver.openOutputStream(target, "w")).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (!copy.cancelled) {
                            val count = input.read(buffer)
                            if (count == -1) {
                                written = true
                                break
                            }
                            if (!copy.cancelled) output.write(buffer, 0, count)
                        }
                    }
                }
            }
        } catch (_: Exception) {
            written = false
        }
        val completed = copy.settle()
        val saved = completed && written
        val removed = saved || runCatching {
            DocumentsContract.deleteDocument(contentResolver, target)
        }.getOrDefault(false)
        val error = when {
            !removed -> "Unable to remove the incomplete export"
            completed && !written -> "Unable to save file"
            else -> null
        }
        // Deliver the result only after streams and any incomplete target are settled.
        runOnUiThread { finishSave(pending, saved = saved, error = error) }
    }
}
