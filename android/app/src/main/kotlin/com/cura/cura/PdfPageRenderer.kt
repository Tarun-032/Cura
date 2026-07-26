package com.cura.cura

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlin.concurrent.thread
import kotlin.math.roundToInt

/**
 * Rasterizes an imported PDF with Android's built-in PdfRenderer. Cura keeps the
 * untouched PDF; these private JPEGs exist only so the established ML Kit OCR,
 * geometry parser, thumbnails, and full-page preview can share one input shape.
 */
class PdfPageRenderer(private val activity: MainActivity) : EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL = "com.cura.cura/pdf_import"
        private const val PROGRESS_CHANNEL = "com.cura.cura/pdf_import_progress"
        private const val PDF_DPI = 72f
        private const val TARGET_DPI = 200f
    }

    @Volatile
    private var progressSink: EventChannel.EventSink? = null

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(::handleCall)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROGRESS_CHANNEL)
            .setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "renderPdf" -> renderPdf(call, result)
            else -> result.notImplemented()
        }
    }

    private fun renderPdf(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputDirectory")
        val maxPages = call.argument<Int>("maxPages") ?: 20
        val maxLongEdge = call.argument<Int>("maxLongEdge") ?: 2400
        val jpegQuality = (call.argument<Int>("jpegQuality") ?: 90).coerceIn(1, 100)
        if (sessionId.isNullOrBlank() || inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
            result.error("invalid_arguments", "PDF paths and session id are required.", null)
            return
        }

        thread(name = "cura-pdf-import") {
            try {
                val paths = rasterize(
                    sessionId = sessionId,
                    input = File(inputPath),
                    outputDirectory = File(outputPath),
                    maxPages = maxPages,
                    maxLongEdge = maxLongEdge,
                    jpegQuality = jpegQuality,
                )
                activity.runOnUiThread { result.success(paths) }
            } catch (error: TooManyPagesException) {
                activity.runOnUiThread {
                    result.error("too_many_pages", error.message, error.pageCount)
                }
            } catch (error: SecurityException) {
                activity.runOnUiThread {
                    result.error(
                        "protected_pdf",
                        "Password-protected PDFs are not supported.",
                        null,
                    )
                }
            } catch (error: EmptyPdfException) {
                activity.runOnUiThread {
                    result.error("empty_pdf", error.message, null)
                }
            } catch (error: IOException) {
                activity.runOnUiThread {
                    result.error("invalid_pdf", error.message ?: "Could not open PDF.", null)
                }
            } catch (error: IllegalArgumentException) {
                activity.runOnUiThread {
                    result.error("invalid_pdf", error.message ?: "Could not render PDF.", null)
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("render_failed", error.message ?: "Could not render PDF.", null)
                }
            }
        }
    }

    private fun rasterize(
        sessionId: String,
        input: File,
        outputDirectory: File,
        maxPages: Int,
        maxLongEdge: Int,
        jpegQuality: Int,
    ): List<String> {
        require(input.isFile) { "The selected PDF is no longer available." }
        outputDirectory.mkdirs()

        ParcelFileDescriptor.open(input, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                val pageCount = renderer.pageCount
                if (pageCount == 0) throw EmptyPdfException()
                if (pageCount > maxPages) throw TooManyPagesException(pageCount, maxPages)

                val paths = ArrayList<String>(pageCount)
                for (index in 0 until pageCount) {
                    renderer.openPage(index).use { page ->
                        val baseLongEdge = maxOf(page.width, page.height)
                        require(baseLongEdge > 0) { "PDF page has invalid dimensions." }
                        val dpiScale = TARGET_DPI / PDF_DPI
                        val edgeScale = maxLongEdge.toFloat() / baseLongEdge.toFloat()
                        val scale = minOf(dpiScale, edgeScale)
                        val width = (page.width * scale).roundToInt().coerceAtLeast(1)
                        val height = (page.height * scale).roundToInt().coerceAtLeast(1)
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        try {
                            // PdfRenderer leaves transparent regions untouched. Medical reports
                            // are paper documents, so flatten onto white before JPEG encoding.
                            bitmap.eraseColor(Color.WHITE)
                            val matrix = Matrix().apply { postScale(scale, scale) }
                            page.render(
                                bitmap,
                                null,
                                matrix,
                                PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                            )
                            val output = File(
                                outputDirectory,
                                "page-${(index + 1).toString().padStart(3, '0')}.jpg",
                            )
                            FileOutputStream(output).use { stream ->
                                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, stream)) {
                                    error("Could not encode PDF page ${index + 1}.")
                                }
                            }
                            paths.add(output.absolutePath)
                        } finally {
                            bitmap.recycle()
                        }
                    }
                    sendProgress(sessionId, index + 1, pageCount)
                }
                return paths
            }
        }
    }

    private fun sendProgress(sessionId: String, current: Int, total: Int) {
        activity.runOnUiThread {
            progressSink?.success(
                mapOf(
                    "sessionId" to sessionId,
                    "current" to current,
                    "total" to total,
                ),
            )
        }
    }

    private class TooManyPagesException(val pageCount: Int, maxPages: Int) :
        Exception("PDF has $pageCount pages; the limit is $maxPages.")

    private class EmptyPdfException : IOException("PDF does not contain any pages.")
}
