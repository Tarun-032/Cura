package com.cura.cura

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Writes user-requested exports to the public Downloads/Cura collection through
 * MediaStore. Android 10+ owns the filesystem access, so Cura needs no broad
 * storage permission and never sees paths outside this one export destination.
 */
class PdfDownloadsSaver(private val activity: MainActivity) {
    companion object {
        private const val CHANNEL = "com.cura.cura/export"
        private const val MIME_TYPE = "application/pdf"
        private val RELATIVE_PATH = "${Environment.DIRECTORY_DOWNLOADS}/Cura/"
    }

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleCall)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supportsAutomaticDownloads" ->
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)

            "savePdfToDownloads" -> savePdf(call, result)
            else -> result.notImplemented()
        }
    }

    private fun savePdf(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "unsupported_version",
                "Automatic Downloads export requires Android 10 or newer.",
                null,
            )
            return
        }

        val requestedName = call.argument<String>("fileName")
        val bytes = call.argument<ByteArray>("bytes")
        if (requestedName.isNullOrBlank() || bytes == null) {
            result.error("invalid_arguments", "A PDF filename and bytes are required.", null)
            return
        }

        // ContentResolver I/O can take seconds for a camera-heavy PDF. Keep it
        // off Android's UI thread, then deliver the channel result on that thread.
        thread(name = "cura-pdf-export") {
            try {
                val savedName = writePdf(requestedName, bytes)
                activity.runOnUiThread { result.success(savedName) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("save_failed", error.message ?: "Could not save PDF.", null)
                }
            }
        }
    }

    private fun writePdf(requestedName: String, bytes: ByteArray): String {
        val resolver = activity.contentResolver
        val displayName = uniqueDisplayName(safePdfName(requestedName))
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, MIME_TYPE)
            put(MediaStore.Downloads.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("Android could not create the export file.")
        try {
            resolver.openOutputStream(uri, "w")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: error("Android could not open the export file.")

            val complete = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            resolver.update(uri, complete, null, null)
            return displayName
        } catch (error: Exception) {
            // Never leave a half-written PDF visible in Downloads.
            resolver.delete(uri, null, null)
            throw error
        }
    }

    /** Returns name.pdf, name-2.pdf, ... without replacing an earlier export. */
    private fun uniqueDisplayName(baseName: String): String {
        if (!displayNameExists(baseName)) return baseName

        val stem = baseName.removeSuffix(".pdf")
        var suffix = 2
        while (true) {
            val candidate = "$stem-$suffix.pdf"
            if (!displayNameExists(candidate)) return candidate
            suffix++
        }
    }

    private fun displayNameExists(displayName: String): Boolean {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection =
            "${MediaStore.Downloads.RELATIVE_PATH} = ? AND " +
                "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        val args = arrayOf(RELATIVE_PATH, displayName)
        return activity.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            args,
            null,
        )?.use { cursor -> cursor.moveToFirst() } ?: false
    }

    private fun safePdfName(requestedName: String): String {
        val leaf = requestedName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[\\\\/:*?\"<>|]"), "-")
            .trim(' ', '.')
        val safeLeaf = leaf.ifBlank { "cura-document" }
        return if (safeLeaf.endsWith(".pdf", ignoreCase = true)) {
            safeLeaf
        } else {
            "$safeLeaf.pdf"
        }
    }
}
