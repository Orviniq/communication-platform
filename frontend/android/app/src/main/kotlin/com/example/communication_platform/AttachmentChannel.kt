package com.example.communication_platform

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ext.SdkExtensions
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The attachment boundary (ADR-089): the system photo picker, the system file
 * picker, the camera app, and Open, Save and Share of a verified file.
 *
 * Every picker is a system intent this application starts and the user
 * answers, so the application holds no storage, media or camera permission.
 * It declares no `CAMERA` permission on purpose: a declared and refused one
 * makes `ACTION_IMAGE_CAPTURE` throw a `SecurityException`.
 *
 * A picked file is copied into `secure_attachment_cache/outgoing/<id>/` on one
 * worker thread, counted against the byte limit Dart gives, and answered by
 * path; a photo is re-encoded there first. Open, Save and Share take only a
 * regular file under `secure_attachment_cache/plain/`, which is where verified
 * decrypted files live, so nothing else in the private cache can leave it.
 *
 * Nothing here logs. A URI, a name, a path, a type or a size never reaches
 * logcat.
 */
class AttachmentChannel(private val activity: Activity) {
    companion object {
        const val NAME = "communication_platform/attachments"

        private const val PICK_REQUEST_CODE = 9201
        private const val SAVE_REQUEST_CODE = 9202

        private const val CACHE_DIRECTORY = "secure_attachment_cache"
        private const val OUTGOING_DIRECTORY = "outgoing"
        private const val PLAIN_DIRECTORY = "plain"
        private const val CAPTURE_NAME = "capture.jpg"
        private const val CAPTURED_PHOTO_NAME = "photo.jpg"

        // A photo's original is copied under a name that no re-encoded output
        // can take, because every output ends in `.jpg`.
        private const val PHOTO_SOURCE_NAME = "source.bin"
        private const val DEFAULT_NAME = "attachment"
        private const val OCTET_STREAM = "application/octet-stream"

        private const val MAX_NAME_LENGTH = 128

        // The file systems under the cache directory take 255 bytes of UTF-8
        // in one name, and 128 characters can need up to 512.
        private const val MAX_NAME_BYTES = 255
        private const val MAX_IMAGE_SIDE = 2048
        private const val JPEG_QUALITY = 82

        // The descriptor refuses a width or a height above this.
        private const val MAX_DESCRIPTOR_SIDE = 8192
        private const val COPY_BUFFER_BYTES = 64 * 1024

        private const val BUSY = "busy"
        private const val TOO_LARGE = "tooLarge"
        private const val UNREADABLE = "unreadable"
        private const val UNSUPPORTED_IMAGE = "unsupportedImage"
        private const val NO_CAMERA_APP = "noCameraApp"
        private const val NO_APP = "noApp"
        private const val WRITE_FAILED = "writeFailed"
        private const val INVALID_ARGUMENT = "invalid_argument"
        private const val SHARE_FAILED = "share_failed"

        // One thread for every copy, re-encode and save in the process, so a
        // picked file is never processed beside another and the main thread
        // never waits on a content provider.
        private val worker = Executors.newSingleThreadExecutor()
        private val random = SecureRandom()
    }

    private enum class PickKind(val wireName: String) {
        PHOTO("photo"),
        FILE("file"),
        CAMERA("camera");

        companion object {
            fun named(value: String?): PickKind? = entries.firstOrNull { it.wireName == value }
        }
    }

    private sealed class Pending(val result: MethodChannel.Result, val requestCode: Int)

    private class PendingPick(
        result: MethodChannel.Result,
        val kind: PickKind,
        val maxBytes: Long,
        // The directory a capture writes into, made before the camera starts
        // because the camera needs its URI. Null for the two pickers.
        val captureDirectory: File?,
    ) : Pending(result, PICK_REQUEST_CODE)

    private class PendingSave(
        result: MethodChannel.Result,
        val source: File,
    ) : Pending(result, SAVE_REQUEST_CODE)

    // What the worker hands back to the main thread. [made] is the directory
    // the answer points into, deleted if nobody is waiting for it any more.
    private class Answer(
        val value: Any? = null,
        val error: String? = null,
        val made: File? = null,
    )

    private class Refusal(val code: String) : Exception()

    private class Decoded(val bitmap: Bitmap, val orientation: Int)

    private val context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    // The one request waiting on an activity result: a pick or a save. Read
    // and written on the main thread only, and held until its answer is sent,
    // through the worker's copy, so a second request is refused rather than
    // allowed to take the first one's result.
    private var pending: Pending? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, NAME).also { it.setMethodCallHandler(::handle) }
    }

    /**
     * The engine is going. Its isolate cannot receive an answer, so the waiting
     * request is dropped here, and a result that arrives later finds nothing
     * pending and is dropped too.
     */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        val request = pending
        pending = null
        if (request is PendingPick) {
            request.captureDirectory?.let { directory ->
                worker.execute { directory.deleteRecursively() }
            }
        }
    }

    /**
     * Called by the activity after `super.onActivityResult`, which is where the
     * Flutter embedding hands results to plugins.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST_CODE && requestCode != SAVE_REQUEST_CODE) {
            return
        }
        val request = pending
        if (request == null || request.requestCode != requestCode) {
            // Started by a process that has since died, or by an engine that has
            // gone: nobody is waiting for it. The sweep of the outgoing
            // directory deletes whatever a camera left there.
            return
        }
        when (request) {
            is PendingPick -> pickResult(request, resultCode, data)
            is PendingSave -> saveResult(request, resultCode, data)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "privateCacheDirectory" -> result.success(cacheRoot().absolutePath)
            "pick" -> pick(call, result)
            "openVerifiedFile" -> openVerifiedFile(call, result)
            "saveVerifiedFile" -> saveVerifiedFile(call, result)
            "shareVerifiedFile" -> shareVerifiedFile(call, result)
            else -> result.notImplemented()
        }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error(BUSY, null, null)
            return
        }
        val kind = PickKind.named(call.argument<Any>("kind") as? String)
        val maxBytes = (call.argument<Any>("maxBytes") as? Number)?.toLong()
        if (kind == null || maxBytes == null || maxBytes <= 0) {
            result.error(INVALID_ARGUMENT, null, null)
            return
        }
        when (kind) {
            PickKind.PHOTO -> launch(photoIntent(), PendingPick(result, kind, maxBytes, null), NO_APP)
            PickKind.FILE -> launch(
                Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .setType("*/*")
                    .addCategory(Intent.CATEGORY_OPENABLE),
                PendingPick(result, kind, maxBytes, null),
                NO_APP,
            )
            PickKind.CAMERA -> capture(result, maxBytes)
        }
    }

    // The system photo picker where the device has it: API 33 and later, and
    // API 30 to 32 once the R extension reaches version 2, which is where
    // `ACTION_PICK_IMAGES` is "also in R Extensions 2". Elsewhere the generic
    // content picker, narrowed to pictures.
    private fun photoIntent(): Intent {
        val photoPicker = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ||
            (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2
                )
        return if (photoPicker) {
            Intent(MediaStore.ACTION_PICK_IMAGES).setType("image/*")
        } else {
            Intent(Intent.ACTION_GET_CONTENT)
                .setType("image/*")
                .addCategory(Intent.CATEGORY_OPENABLE)
        }
    }

    private fun capture(result: MethodChannel.Result, maxBytes: Long) {
        var directory: File? = null
        val uri = try {
            val made = newOutgoingDirectory().also { directory = it }
            FileProvider.getUriForFile(activity, authority(), File(made, CAPTURE_NAME))
        } catch (_: Exception) {
            directory?.deleteRecursively()
            result.error(UNREADABLE, null, null)
            return
        }
        // The grant has to reach the camera app, which writes the picture
        // through the URI. Setting the ClipData to the URI is what carries the
        // flags to it.
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
            .putExtra(MediaStore.EXTRA_OUTPUT, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        intent.clipData = ClipData.newRawUri("", uri)
        launch(intent, PendingPick(result, PickKind.CAMERA, maxBytes, directory), NO_CAMERA_APP)
    }

    // Starts the activity for [request]. The code catches what a missing app
    // throws instead of asking first, so the manifest needs no `<queries>`.
    private fun launch(intent: Intent, request: Pending, unavailable: String) {
        pending = request
        try {
            activity.startActivityForResult(intent, request.requestCode)
        } catch (_: ActivityNotFoundException) {
            abandon(request, unavailable)
        } catch (_: SecurityException) {
            abandon(request, unavailable)
        }
    }

    private fun abandon(request: Pending, code: String) {
        pending = null
        if (request is PendingPick) {
            request.captureDirectory?.let { directory ->
                worker.execute { directory.deleteRecursively() }
            }
        }
        request.result.error(code, null, null)
    }

    private fun pickResult(request: PendingPick, resultCode: Int, data: Intent?) {
        val captureDirectory = request.captureDirectory
        if (captureDirectory != null) {
            worker.execute {
                // A camera app that wrote to EXTRA_OUTPUT commonly answers with
                // no Intent at all, so what it took is the file, not the data.
                val capture = File(captureDirectory, CAPTURE_NAME)
                if (resultCode != Activity.RESULT_OK || !capture.isFile || capture.length() == 0L) {
                    captureDirectory.deleteRecursively()
                    deliver(request, Answer())
                } else {
                    deliver(request, processCapture(captureDirectory, capture, request.maxBytes))
                }
            }
            return
        }
        val uri = if (resultCode == Activity.RESULT_OK) data?.let(::firstUri) else null
        if (uri == null) {
            pending = null
            request.result.success(null)
            return
        }
        worker.execute { deliver(request, copyAndProcess(uri, request)) }
    }

    private fun firstUri(data: Intent): Uri? =
        data.data ?: data.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri

    // Answers [request] on the main thread, unless it stopped waiting while
    // the worker ran.
    private fun deliver(request: Pending, answer: Answer) {
        main.post {
            if (pending !== request) {
                answer.made?.let { directory -> worker.execute { directory.deleteRecursively() } }
                return@post
            }
            pending = null
            val error = answer.error
            if (error != null) {
                request.result.error(error, null, null)
            } else {
                request.result.success(answer.value)
            }
        }
    }

    // Worker thread.
    private fun copyAndProcess(uri: Uri, request: PendingPick): Answer {
        var directory: File? = null
        return try {
            val resolver = context.contentResolver
            val (displayName, declaredSize) = describe(uri)
            // The declared size only refuses early. It is never what lets a
            // copy through: the counted copy below is.
            if (declaredSize != null && declaredSize > request.maxBytes) {
                throw Refusal(TOO_LARGE)
            }
            val type = resolver.getType(uri)?.trim()?.lowercase()
            val made = newOutgoingDirectory().also { directory = it }
            val name = safeName(displayName)
            val reencode = request.kind == PickKind.PHOTO && type != "image/gif"
            val copy = File(made, if (reencode) PHOTO_SOURCE_NAME else name)
            val input = resolver.openInputStream(uri) ?: throw Refusal(UNREADABLE)
            input.use { source ->
                FileOutputStream(copy).use { sink -> copyBounded(source, sink, request.maxBytes) }
            }
            val value = when {
                request.kind == PickKind.FILE -> fileAnswer(copy, name, type)
                !reencode -> gifAnswer(copy, name)
                else -> reencodedAnswer(made, copy, jpegName(displayName), request.maxBytes)
            }
            Answer(value = value, made = made)
        } catch (refusal: Refusal) {
            directory?.deleteRecursively()
            Answer(error = refusal.code)
        } catch (_: Exception) {
            directory?.deleteRecursively()
            Answer(error = UNREADABLE)
        }
    }

    // Worker thread.
    private fun processCapture(directory: File, capture: File, maxBytes: Long): Answer =
        try {
            Answer(
                value = reencodedAnswer(directory, capture, CAPTURED_PHOTO_NAME, maxBytes),
                made = directory,
            )
        } catch (refusal: Refusal) {
            directory.deleteRecursively()
            Answer(error = refusal.code)
        } catch (_: Exception) {
            directory.deleteRecursively()
            Answer(error = UNREADABLE)
        }

    // The display name and the declared size, and nothing else the provider
    // holds. A provider that cannot be asked leaves both unknown.
    private fun describe(uri: Uri): Pair<String?, Long?> {
        try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    val name = if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        cursor.getString(nameIndex)
                    } else {
                        null
                    }
                    val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        cursor.getLong(sizeIndex)
                    } else {
                        null
                    }
                    return name to size
                }
            }
        } catch (_: Exception) {
            // Unknown, as for a provider that answers no row.
        }
        return null to null
    }

    private fun copyBounded(source: InputStream, sink: OutputStream, maxBytes: Long) {
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        var total = 0L
        while (true) {
            val read = source.read(buffer)
            if (read < 0) {
                return
            }
            total += read
            if (total > maxBytes) {
                throw Refusal(TOO_LARGE)
            }
            sink.write(buffer, 0, read)
        }
    }

    private fun fileAnswer(copy: File, name: String, type: String?): Map<String, Any> {
        val answer = mutableMapOf<String, Any>(
            "path" to copy.absolutePath,
            "name" to name,
            "mime" to (type ?: OCTET_STREAM),
            "size" to copy.length(),
            "kind" to "file",
        )
        if (type != null && type.startsWith("image/")) {
            orientedBounds(copy)?.let { (width, height) ->
                if (width <= MAX_DESCRIPTOR_SIDE && height <= MAX_DESCRIPTOR_SIDE) {
                    answer["width"] = width
                    answer["height"] = height
                }
            }
        }
        return answer
    }

    // A GIF is sent as it is: re-encoding it would keep one frame.
    private fun gifAnswer(copy: File, name: String): Map<String, Any> {
        val (width, height) = orientedBounds(copy) ?: throw Refusal(UNSUPPORTED_IMAGE)
        if (width > MAX_DESCRIPTOR_SIDE || height > MAX_DESCRIPTOR_SIDE) {
            throw Refusal(UNSUPPORTED_IMAGE)
        }
        return mapOf(
            "path" to copy.absolutePath,
            "name" to name,
            "mime" to "image/gif",
            "size" to copy.length(),
            "kind" to "image",
            "width" to width,
            "height" to height,
        )
    }

    // Decodes [source] at a bounded size, draws it upright on opaque white
    // with its longest side at most 2048 px, and writes it as a JPEG of
    // quality 82 named [name]. The output is a new bitmap's pixels, so no
    // metadata of the original - location, camera, time - survives it.
    private fun reencodedAnswer(directory: File, source: File, name: String, maxBytes: Long): Map<String, Any> {
        val decoded = decodeBounded(source) ?: throw Refusal(UNSUPPORTED_IMAGE)
        val output = try {
            flatten(decoded)
        } catch (_: OutOfMemoryError) {
            throw Refusal(UNSUPPORTED_IMAGE)
        } finally {
            decoded.bitmap.recycle()
        }
        val target = File(directory, name)
        val width = output.width
        val height = output.height
        try {
            val written = FileOutputStream(target).use {
                output.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it)
            }
            if (!written) {
                throw Refusal(UNSUPPORTED_IMAGE)
            }
        } finally {
            output.recycle()
        }
        source.delete()
        if (target.length() > maxBytes) {
            throw Refusal(TOO_LARGE)
        }
        return mapOf(
            "path" to target.absolutePath,
            "name" to name,
            "mime" to "image/jpeg",
            "size" to target.length(),
            "kind" to "image",
            "width" to width,
            "height" to height,
        )
    }

    // `ImageDecoder` applies the EXIF orientation itself (from API 28 it
    // decodes through Skia's `ExifOrientationBehavior::kRespect`), and samples
    // straight to the target size. `BitmapFactory` ignores the orientation, so
    // below API 28 it is read here, once, and applied when the picture is
    // drawn.
    private fun decodeBounded(file: File): Decoded? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                // A software bitmap, because it is drawn on a software canvas.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val scale = fitScale(info.size.width.toFloat(), info.size.height.toFloat())
                if (scale < 1f) {
                    decoder.setTargetSize(
                        max(1, (info.size.width * scale).roundToInt()),
                        max(1, (info.size.height * scale).roundToInt()),
                    )
                }
            }
            Decoded(bitmap, ExifInterface.ORIENTATION_NORMAL)
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                null
            } else {
                // The largest power of two that keeps the longest side at
                // 2048 px or more, so sampling never drops below the output.
                var sample = 1
                while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_IMAGE_SIDE) {
                    sample *= 2
                }
                val options = BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                BitmapFactory.decodeFile(file.path, options)?.let { Decoded(it, exifOrientation(file)) }
            }
        }
    } catch (_: Exception) {
        null
    } catch (_: OutOfMemoryError) {
        null
    }

    private fun flatten(decoded: Decoded): Bitmap {
        val matrix = orientationMatrix(decoded.orientation)
        val bounds = RectF(0f, 0f, decoded.bitmap.width.toFloat(), decoded.bitmap.height.toFloat())
        matrix.mapRect(bounds)
        matrix.postTranslate(-bounds.left, -bounds.top)
        val scale = fitScale(bounds.width(), bounds.height())
        matrix.postScale(scale, scale)
        val width = (bounds.width() * scale).roundToInt().coerceIn(1, MAX_IMAGE_SIDE)
        val height = (bounds.height() * scale).roundToInt().coerceIn(1, MAX_IMAGE_SIDE)
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawColor(Color.WHITE)
        canvas.drawBitmap(decoded.bitmap, matrix, Paint(Paint.FILTER_BITMAP_FLAG))
        return output
    }

    // At most 1: a picture is made smaller, never larger.
    private fun fitScale(width: Float, height: Float): Float =
        min(1f, MAX_IMAGE_SIDE / max(width, height))

    private fun orientationMatrix(orientation: Int): Matrix = Matrix().apply {
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                setRotate(180f)
                postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                setRotate(90f)
                postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                setRotate(-90f)
                postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
        }
    }

    private fun exifOrientation(file: File): Int = try {
        ExifInterface(file.path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    } catch (_: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    // The width and the height as the picture is shown, from a decode that
    // reads the header and allocates no pixels.
    private fun orientedBounds(file: File): Pair<Int, Int>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            BitmapFactory.decodeFile(file.path, bounds)
        } catch (_: Exception) {
            return null
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return null
        }
        return when (exifOrientation(file)) {
            ExifInterface.ORIENTATION_TRANSPOSE,
            ExifInterface.ORIENTATION_ROTATE_90,
            ExifInterface.ORIENTATION_TRANSVERSE,
            ExifInterface.ORIENTATION_ROTATE_270,
            -> bounds.outHeight to bounds.outWidth
            else -> bounds.outWidth to bounds.outHeight
        }
    }

    private fun openVerifiedFile(call: MethodCall, result: MethodChannel.Result) {
        val file = verifiedPlainFile(call.argument<Any>("path") as? String)
        val uri = file?.let(::contentUri)
        if (uri == null) {
            result.error(INVALID_ARGUMENT, null, null)
            return
        }
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, safeShareMime(call.argument<Any>("mime") as? String))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            activity.startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            result.error(NO_APP, null, null)
        } catch (_: SecurityException) {
            result.error(NO_APP, null, null)
        }
    }

    private fun saveVerifiedFile(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error(BUSY, null, null)
            return
        }
        val file = verifiedPlainFile(call.argument<Any>("path") as? String)
        val name = call.argument<Any>("name") as? String
        if (file == null || name == null) {
            result.error(INVALID_ARGUMENT, null, null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(safeShareMime(call.argument<Any>("mime") as? String))
            .putExtra(Intent.EXTRA_TITLE, safeName(name))
        launch(intent, PendingSave(result, file), NO_APP)
    }

    private fun saveResult(request: PendingSave, resultCode: Int, data: Intent?) {
        val target = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (target == null) {
            pending = null
            request.result.success(false)
            return
        }
        worker.execute { deliver(request, writeTo(request.source, target)) }
    }

    // Worker thread. A failed write leaves the chosen document as the provider
    // left it: it may be one the user chose to overwrite, so it is not deleted.
    private fun writeTo(source: File, target: Uri): Answer {
        return try {
            val sink = openForWrite(target) ?: return Answer(error = WRITE_FAILED)
            sink.use { out -> source.inputStream().use { it.copyTo(out, COPY_BUFFER_BYTES) } }
            Answer(value = true)
        } catch (_: Exception) {
            Answer(error = WRITE_FAILED)
        }
    }

    // "wt" truncates an existing document the user chose to replace. Not every
    // provider accepts it, and those get "w".
    private fun openForWrite(target: Uri): OutputStream? = try {
        context.contentResolver.openOutputStream(target, "wt")
    } catch (_: Exception) {
        context.contentResolver.openOutputStream(target, "w")
    }

    private fun shareVerifiedFile(call: MethodCall, result: MethodChannel.Result) {
        val file = verifiedPlainFile(call.argument<Any>("path") as? String)
        if (file == null) {
            result.error(INVALID_ARGUMENT, null, null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(activity, authority(), file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = safeShareMime(call.argument<Any>("mime") as? String)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(intent, null))
            result.success(null)
        } catch (_: Exception) {
            result.error(SHARE_FAILED, null, null)
        }
    }

    // A regular file whose canonical path is inside `plain/`, or nothing.
    // Canonical, so neither `..` nor a symbolic link leads out of it.
    private fun verifiedPlainFile(path: String?): File? {
        if (path == null) {
            return null
        }
        return try {
            val file = File(path).canonicalFile
            val plain = File(cacheRoot(), PLAIN_DIRECTORY).canonicalFile
            if (file.path.startsWith(plain.path + File.separator) && file.isFile) file else null
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    private fun contentUri(file: File): Uri? = try {
        FileProvider.getUriForFile(activity, authority(), file)
    } catch (_: IllegalArgumentException) {
        null
    }

    private fun authority(): String = "${context.packageName}.attachments"

    private fun cacheRoot(): File = context.cacheDir.resolve(CACHE_DIRECTORY)

    // `outgoing/<id>`, with 32 lowercase hexadecimal characters of id.
    private fun newOutgoingDirectory(): File {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        val digits = "0123456789abcdef"
        val id = buildString {
            for (byte in bytes) {
                val value = byte.toInt() and 0xff
                append(digits[value shr 4])
                append(digits[value and 0x0f])
            }
        }
        val directory = File(File(cacheRoot(), OUTGOING_DIRECTORY), id)
        if (!directory.mkdirs()) {
            throw IOException()
        }
        return directory
    }

    // The display name without a path, without control characters, and at
    // most 128 characters; `attachment` when nothing is left.
    private fun safeName(value: String?): String {
        val segment = (value ?: "").replace('\\', '/').substringAfterLast('/')
        val cleaned = segment.filterNot { it.isISOControl() }.trim()
        val bounded = bounded(cleaned, MAX_NAME_LENGTH, MAX_NAME_BYTES).trim()
        return if (bounded.isEmpty() || bounded == "." || bounded == "..") DEFAULT_NAME else bounded
    }

    // The base name of the original with `.jpg`.
    private fun jpegName(displayName: String?): String {
        val safe = safeName(displayName)
        val base = safe.substringBeforeLast('.', safe).trim().ifEmpty { DEFAULT_NAME }
        val suffix = ".jpg"
        val boundedBase = bounded(base, MAX_NAME_LENGTH - suffix.length, MAX_NAME_BYTES - suffix.length)
            .trim()
            .ifEmpty { DEFAULT_NAME }
        return boundedBase + suffix
    }

    // At most [maxChars] characters and [maxBytes] bytes of UTF-8, never
    // ending in half of a surrogate pair.
    private fun bounded(value: String, maxChars: Int, maxBytes: Int): String {
        var end = min(value.length, maxChars)
        while (end > 0 &&
            (
                Character.isHighSurrogate(value[end - 1]) ||
                    value.substring(0, end).toByteArray(Charsets.UTF_8).size > maxBytes
                )
        ) {
            end--
        }
        return value.substring(0, end)
    }

    private fun safeShareMime(value: String?): String {
        val normalized = value?.trim()?.lowercase() ?: return OCTET_STREAM
        val safe = setOf(
            "image/jpeg", "image/png", "image/webp", "image/gif",
            "audio/mpeg", "audio/ogg", "audio/wav", "text/plain", "application/pdf",
        )
        return if (normalized in safe) normalized else OCTET_STREAM
    }
}
