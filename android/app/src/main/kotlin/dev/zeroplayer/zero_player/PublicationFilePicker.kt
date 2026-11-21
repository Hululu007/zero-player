package dev.zeroplayer.zero_player

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.concurrent.Executors

/** Reads a user-selected document on request. The Dart importer owns disk reservations. */
internal class PublicationFilePicker(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var active: Selection? = null

    private class Selection(val id: String, var result: MethodChannel.Result?) {
        val cancellation = CancellationSignal()
        var pickerOpen = true
        var uri: Uri? = null
        var reading = false
        @Volatile var closed = false
        @Volatile var input: InputStream? = null
    }

    fun install(messenger: BinaryMessenger) {
        MethodChannel(messenger, "zero_player/publications_files").setMethodCallHandler { call, result ->
            val id = call.arguments as? String
            when (call.method) {
                "choose" -> choose(call.argument<String>("id"), call.argument<Boolean>("backup") == true, result)
                "read" -> read(id, result)
                "release" -> {
                    active?.takeIf { it.id == id }?.let { release(it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun choose(id: String?, backup: Boolean, result: MethodChannel.Result) {
        if (id == null || active != null) {
            result.error("busy", "图书选择仍在进行", null)
            return
        }
        active = Selection(id, result)
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = if (backup) "*/*" else "application/*"
                val mime = if (backup) {
                    arrayOf("application/json", "text/plain", "application/octet-stream")
                } else {
                    arrayOf("application/pdf", "application/epub+zip", "application/zip",
                        "application/x-zip-compressed", "application/octet-stream")
                }
                putExtra(Intent.EXTRA_MIME_TYPES, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, ActivityRequestCodes.PUBLICATION_FILE)
        } catch (_: Exception) {
            active = null
            unavailable(result)
        }
    }

    fun onResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != ActivityRequestCodes.PUBLICATION_FILE) return false
        val selection = active ?: return true
        selection.pickerOpen = false
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content" || selection.closed) {
            release(selection)
            return true
        }
        selection.uri = uri
        worker.execute {
            try {
                val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
                val details = requireNotNull(activity.contentResolver.query(
                    uri, columns, null, null, null, selection.cancellation
                )).use { cursor ->
                    check(cursor.moveToFirst())
                    val name = cursor.getString(0)
                    val size = if (cursor.isNull(1)) null else cursor.getLong(1).takeIf { it >= 0 }
                    mapOf("name" to name, "size" to size)
                }
                activity.runOnUiThread {
                    selection.result?.success(details)
                    selection.result = null
                }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    selection.result?.let { unavailable(it) }
                    selection.result = null
                }
            }
        }
        return true
    }

    private fun read(id: String?, result: MethodChannel.Result) {
        val selection = active?.takeIf { it.id == id && !it.closed }
        val uri = selection?.uri
        if (selection == null || uri == null || selection.reading) {
            unavailable(result)
            return
        }
        selection.reading = true
        worker.execute {
            try {
                val input = selection.input ?: openStream(uri, selection.cancellation).also { selection.input = it }
                if (selection.closed) {
                    input.close()
                    throw IllegalStateException("Selection closed")
                }
                val buffer = ByteArray(512 * 1024)
                val count = input.read(buffer)
                check(count != 0)
                val chunk = if (count == buffer.size) buffer else buffer.copyOf(count.coerceAtLeast(0))
                activity.runOnUiThread {
                    selection.reading = false
                    if (selection.closed) unavailable(result) else result.success(chunk)
                }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    selection.reading = false
                    unavailable(result)
                }
            }
        }
    }

    private fun openStream(uri: Uri, cancellation: CancellationSignal): InputStream {
        val descriptor = requireNotNull(activity.contentResolver.openAssetFileDescriptor(uri, "r", cancellation))
        return try {
            descriptor.createInputStream()
        } catch (error: Exception) {
            descriptor.close()
            throw error
        }
    }

    private fun release(selection: Selection) {
        if (!selection.pickerOpen && active === selection) active = null
        selection.result?.success(null)
        selection.result = null
        if (selection.closed) return
        selection.closed = true
        Thread {
            try { selection.cancellation.cancel() } catch (_: Exception) {}
            try { selection.input?.close() } catch (_: Exception) {}
        }.start()
    }

    private fun unavailable(result: MethodChannel.Result) {
        result.error("document_unavailable", "无法读取所选图书", null)
    }

    fun close() {
        active?.let { release(it) }
        active = null
        worker.shutdown()
    }
}
