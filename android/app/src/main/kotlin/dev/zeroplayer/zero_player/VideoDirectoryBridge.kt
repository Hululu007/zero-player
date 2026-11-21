package dev.zeroplayer.zero_player

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.system.ErrnoException
import android.system.OsConstants
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** SAF grants access only to the directory chosen by the user. */
class VideoDirectoryBridge(private val activity: Activity) {
    private val copies = ConcurrentHashMap<String, AtomicBoolean>()
    fun cancel(path: String?) { path?.let { copies[it]?.set(true) } }
    private var pending: MethodChannel.Result? = null

    fun choose(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "Directory picker is already open", null)
            return
        }
        try {
            pending = result
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }, ActivityRequestCodes.VIDEO_DIRECTORY)
        } catch (_: Exception) {
            pending = null
            result.error("directory_failed", "无法打开目录选择器", null)
        }
    }

    fun onResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != ActivityRequestCodes.VIDEO_DIRECTORY) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            activity.contentResolver.takePersistableUriPermission(uri, flags)
            result.success(uri.toString())
        } catch (_: Exception) {
            result.error("directory_failed", "无法保留目录授权，请重新选择", null)
        }
        return true
    }

    fun verify(call: MethodCall, result: MethodChannel.Result, publication: Boolean = false) {
        Thread {
            try {
                val tree = Uri.parse(requireNotNull(call.argument<String>("directory")))
                val name = requireNotNull(call.argument<String>("name"))
                val expected = requireNotNull(call.argument<String>("digest"))
                val resolver = activity.contentResolver
                if (publication) requireDirectoryGrant(resolver, tree)
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                var found: String? = null
                requireNotNull(resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)).use { cursor ->
                    while (cursor.moveToNext()) {
                        if (cursor.getString(1) != name) continue
                        if (found != null) throw DestinationConflict()
                        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                        val digest = java.security.MessageDigest.getInstance("SHA-256")
                        requireNotNull(resolver.openInputStream(uri)).use { input ->
                            val buffer = ByteArray(128 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                digest.update(buffer, 0, count)
                            }
                        }
                        if (digest.digest().joinToString("") { "%02x".format(it) } != expected) {
                            throw DestinationConflict()
                        }
                        found = uri.toString()
                    }
                }
                activity.runOnUiThread { result.success(found) }
            } catch (error: Exception) {
                val code = if (publication) publicationFailureCode(error) else "verify_failed"
                activity.runOnUiThread { result.error(code, "无法核验已保存文件，请检查授权或选择其他目录", null) }
            }
        }.start()
    }

    fun save(call: MethodCall, result: MethodChannel.Result, mime: String = "video/mp4") {
        val path = call.argument<String>("path")
        val directory = call.argument<String>("directory")
        val name = call.argument<String>("name")
        val publication = mime != "video/mp4"
        if (path == null || directory == null || name == null || !File(path).isFile) {
            result.error("invalid_file", if (publication) "待保存的图书不存在" else "待保存的视频不存在", null)
            return
        }
        val cancelled = AtomicBoolean(false)
        copies[path] = cancelled
        Thread {
            var created: Uri? = null
            try {
                val resolver = activity.contentResolver
                val tree = Uri.parse(directory)
                if (publication) requireDirectoryGrant(resolver, tree)
                val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val existing = mutableSetOf<String>()
                requireNotNull(resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)).use { cursor ->
                    while (cursor.moveToNext()) {
                        existing.add(cursor.getString(0))
                        if (cursor.getString(1) == name) throw DestinationConflict()
                    }
                }
                val target = requireNotNull(DocumentsContract.createDocument(resolver, parent, mime, name))
                if (existing.contains(DocumentsContract.getDocumentId(target))) throw DestinationConflict()
                created = target
                // Recovery uses the journaled random identity; providers must preserve it.
                requireNotNull(resolver.query(target, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)).use { cursor ->
                    check(cursor.moveToFirst())
                    if (cursor.getString(0) != name) throw DestinationConflict()
                }
                requireNotNull(resolver.openOutputStream(target, "w")).use { output ->
                    File(path).inputStream().use { input ->
                        val buffer = ByteArray(128 * 1024)
                        while (true) {
                            check(!cancelled.get())
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                }
                check(!cancelled.get())
                activity.runOnUiThread { result.success(target.toString()) }
            } catch (error: Exception) {
                created?.let { try { DocumentsContract.deleteDocument(activity.contentResolver, it) } catch (_: Exception) {} }
                val code = if (publication) publicationFailureCode(error) else "save_failed"
                activity.runOnUiThread { result.error(code, "保存失败，请检查目录授权和剩余空间", null) }
            } finally { copies.remove(path, cancelled) }
        }.start()
    }

    private fun requireDirectoryGrant(resolver: ContentResolver, tree: Uri) {
        if (resolver.persistedUriPermissions.none {
                it.uri == tree && it.isReadPermission && it.isWritePermission
            }) {
            throw SecurityException("Writable directory grant is missing")
        }
    }

    private fun publicationFailureCode(error: Exception): String {
        for (cause in generateSequence<Throwable>(error) { it.cause }.take(8)) {
            when (cause) {
                is DestinationConflict -> return "publication_destination_conflict"
                is SecurityException -> return "publication_directory_permission"
                is ErrnoException -> when (cause.errno) {
                    OsConstants.EACCES, OsConstants.EPERM -> return "publication_directory_permission"
                    OsConstants.ENOSPC, OsConstants.EDQUOT -> return "publication_disk_full"
                    OsConstants.EEXIST -> return "publication_destination_conflict"
                    else -> Unit
                }
                else -> Unit
            }
        }
        return "publication_directory_unavailable"
    }

    private class DestinationConflict : IllegalStateException()

    fun close() {
        pending?.success(null)
        pending = null
    }
}
