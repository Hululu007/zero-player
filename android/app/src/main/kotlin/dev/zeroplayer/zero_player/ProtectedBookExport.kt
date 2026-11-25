package dev.zeroplayer.zero_player

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import android.widget.Toast
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** Two-phase SAF export. Only a URI returned by this create-document request is touched. */
class ProtectedBookExport(private val activity: MainActivity) {
    private class Request(
        val id: String,
        var picker: MethodChannel.Result?,
        val publicationFile: File?,
    ) {
        val cancelled = AtomicBoolean(false)
        @Volatile var output: OutputStream? = null
        @Volatile var worker: Thread? = null
        var uri: Uri? = null
        var verifiedDocument = false
        var written = false
        var writing = false
    }

    private var current: Request? = null
    private val publicationIdPattern = Regex("[a-f0-9]{64}")

    fun choose(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id.isNullOrBlank() || id.length > 96 || current != null) {
            result.error("protected_busy", "Unable to open another export", null)
            return
        }
        try {
            val mime = call.argument<String>("mime") ?: "application/octet-stream"
            val publication = call.argument<String>("publicationId")?.let { sourceId ->
                publicationFile(sourceId, mime, call.argument<Boolean>("publicationLegacy") == true)
            }
            current = Request(id, result, publication)
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
            }
            activity.startActivityForResult(intent, ActivityRequestCodes.PROTECTED_BOOK_EXPORT)
        } catch (_: Exception) {
            current = null
            result.error("protected_picker_failed", "Unable to open the file picker", null)
        }
    }

    private fun publicationFile(id: String, mime: String, legacy: Boolean): File {
        require(publicationIdPattern.matches(id))
        val extension = when (mime) {
            "application/pdf" -> "pdf"
            "application/epub+zip" -> "epub"
            "application/x-mobipocket-ebook" -> "mobi"
            "application/vnd.amazon.mobi8-ebook" -> "azw3"
            else -> throw IllegalArgumentException("Unsupported publication MIME type")
        }
        val directory = if (legacy) "book_documents" else "publications/files"
        return File(activity.filesDir.canonicalFile, "$directory/$id.$extension")
    }

    fun onResult(requestCode: Int, resultCode: Int, intent: Intent?): Boolean {
        if (requestCode != ActivityRequestCodes.PROTECTED_BOOK_EXPORT) return false
        val request = current ?: return true
        val uri = if (resultCode == Activity.RESULT_OK) intent?.data else null
        request.uri = uri
        request.verifiedDocument = try {
            uri != null && uri.scheme == "content" && DocumentsContract.isDocumentUri(activity, uri)
        } catch (_: Exception) { false }
        val picker = request.picker
        request.picker = null
        picker?.success(uri != null && request.verifiedDocument && !request.cancelled.get())
        return true
    }

    fun cancel(call: MethodCall, result: MethodChannel.Result) {
        val request = current
        if (request != null && request.id == call.argument<String>("id")) {
            request.cancelled.set(true)
            closeOutput(request)
            if (request.picker != null) {
                try { activity.finishActivity(ActivityRequestCodes.PROTECTED_BOOK_EXPORT) } catch (_: Exception) {}
            }
        }
        result.success(null)
    }

    fun write(call: MethodCall, result: MethodChannel.Result) {
        val request = current
        val path = call.argument<String>("path")
        if (request == null || request.id != call.argument<String>("id") ||
            request.cancelled.get() || request.uri == null || !request.verifiedDocument ||
            request.writing || request.written || path == null) {
            result.error("protected_cancelled", "Export is no longer available", null)
            return
        }
        val file = try {
            val source = File(path).canonicalFile
            val allowed = if (request.publicationFile != null) {
                source == request.publicationFile
            } else {
                val cache = activity.cacheDir.canonicalFile.path + File.separator
                source.path.startsWith(cache)
            }
            if (!allowed || !source.isFile) {
                result.error("protected_invalid_file", "Export file is outside the approved location", null)
                return
            }
            source
        } catch (_: Exception) {
            result.error("protected_invalid_file", "Unable to inspect the export file", null)
            return
        }
        request.writing = true
        request.worker = Thread {
            try {
                if (request.cancelled.get()) throw InterruptedException()
                val output = activity.contentResolver.openOutputStream(request.uri!!, "w")
                    ?: throw IllegalStateException("Provider refused the document")
                request.output = output
                output.use { sink ->
                    file.inputStream().use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (request.cancelled.get()) throw InterruptedException()
                            val count = input.read(buffer)
                            if (request.cancelled.get()) throw InterruptedException()
                            if (count < 0) break
                            sink.write(buffer, 0, count)
                        }
                        if (request.cancelled.get()) throw InterruptedException()
                        sink.flush()
                        if (request.cancelled.get()) throw InterruptedException()
                    }
                }
                request.output = null
                activity.runOnUiThread {
                    request.writing = false
                    if (request.cancelled.get()) {
                        result.error("protected_cancelled", "Export was cancelled", null)
                    } else {
                        request.written = true
                        result.success(null)
                    }
                }
            } catch (_: Exception) {
                request.output = null
                activity.runOnUiThread {
                    request.writing = false
                    result.error("protected_write_failed", "Export was interrupted or could not be written", null)
                }
            }
        }.also { it.start() }
    }

    fun finish(call: MethodCall, result: MethodChannel.Result) {
        val request = current
        if (request == null || request.id != call.argument<String>("id")) {
            result.error("protected_cleanup_failed", "Unable to confirm cleanup of the created document", null)
            return
        }
        if (request.picker != null || request.writing) {
            result.error("protected_busy", "Export has not stopped", null)
            return
        }
        if (call.argument<Boolean>("commit") == true && request.written && !request.cancelled.get()) {
            current = null
            result.success(true)
            return
        }
        current = null
        cleanup(request) { ok ->
            if (ok) result.success(false)
            else result.error("protected_cleanup_failed", "The created document may remain at the selected location", null)
        }
    }

    private fun cleanup(request: Request, complete: (Boolean) -> Unit) {
        val uri = request.uri
        if (uri == null) {
            complete(true)
            return
        }
        if (!request.verifiedDocument) {
            complete(false)
            return
        }
        Thread {
            val deleted = try {
                DocumentsContract.deleteDocument(activity.contentResolver, uri)
            } catch (_: Exception) {
                false
            }
            activity.runOnUiThread { complete(deleted) }
        }.start()
    }

    private fun closeOutput(request: Request) {
        val output = request.output ?: return
        Thread { try { output.close() } catch (_: Exception) {} }.start()
    }

    fun close() {
        val request = current ?: return
        request.cancelled.set(true)
        closeOutput(request)
        if (request.picker != null) warnResidual()
        request.picker?.success(false)
        request.picker = null
        current = null
        // Do not delete while a provider may still be writing. A process or
        // provider failure can leave a partial document, which is not rollback.
        Thread {
            try { request.worker?.join(2000) } catch (_: InterruptedException) {}
            if (request.worker?.isAlive == true) warnResidual()
            else cleanup(request) { ok -> if (!ok) warnResidual() }
        }.start()
    }

    private fun warnResidual() {
        Log.w("ProtectedBookExport", "Export cleanup could not be confirmed; a created document may remain")
        activity.runOnUiThread {
            Toast.makeText(activity.applicationContext, "导出已中止，目标位置可能有未清理的文件", Toast.LENGTH_LONG).show()
        }
    }

}
