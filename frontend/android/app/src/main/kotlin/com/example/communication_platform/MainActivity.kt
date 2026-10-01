package com.example.communication_platform

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val notificationPermissionRequestCode = 9101
    private var pendingNotificationPermission: MethodChannel.Result? = null
    private var deliveryChannel: MethodChannel? = null
    private var voiceCallChannel: MethodChannel? = null

    // The two boundaries this application owns are Context-bound and shared with
    // the headless engine a deferred catch-up runs in, so there is exactly one
    // implementation of each in the artifact. This activity supplies only what
    // genuinely needs a window or a user: the permission dialog, the settings
    // screen, screen-capture protection and the clipboard.
    private val protectedStorage by lazy { ProtectedStorageChannel(applicationContext) }
    private val messageAlerts by lazy {
        MessageAlertChannel(
            context = applicationContext,
            activity = this,
            requestPermission = ::requestNotificationPermission,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, ProtectedStorageChannel.NAME)
            .setMethodCallHandler { call, result ->
                if (protectedStorage.handle(call, result)) {
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "setSensitiveScreen" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "copySensitiveText" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("invalid_argument", null, null)
                        } else {
                            copySensitiveText(
                                text,
                                call.argument<Int>("clearAfterSeconds") ?: 60,
                            )
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        messageAlerts.attach(messenger)
        // Sustained delivery is attached with this activity, for one reason the
        // headless engines cannot supply: the battery-optimization dialog is an
        // activity, and only an activity can start it. Everything else on this
        // channel is Context-bound and identical in every engine.
        SustainedDelivery.attach(applicationContext, messenger, activity = this)
        // Registering this engine as the delivery owner is what makes a deferred
        // wake-up reuse the isolate the user already has instead of starting a
        // second one beside it. Two isolates would be two token coordinators
        // rotating one refresh token.
        deliveryChannel = BackgroundDelivery.attach(applicationContext, messenger).also {
            BackgroundDelivery.attachForeground(it)
        }
        // A call's microphone and its service (§N rule 11). Attached with this
        // activity and never on a headless engine: the permission dialog needs
        // a window, and the platform starts a `microphone` service only from a
        // visible activity.
        voiceCallChannel = VoiceCall.attach(applicationContext, messenger, activity = this)
        MethodChannel(messenger, "communication_platform/attachments")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "privateCacheDirectory" -> result.success(
                        cacheDir.resolve("secure_attachment_cache").absolutePath,
                    )
                    "shareVerifiedFile" -> {
                        val path = call.argument<String>("path")
                        val mime = safeShareMime(call.argument<String>("mime"))
                        if (path == null) {
                            result.error("invalid_argument", null, null)
                        } else {
                            try {
                                val file = File(path).canonicalFile
                                val cache =
                                    cacheDir.resolve("secure_attachment_cache").canonicalFile
                                if (!file.path.startsWith(cache.path + File.separator) ||
                                    !file.isFile
                                ) {
                                    result.error("invalid_argument", null, null)
                                } else {
                                    val uri = FileProvider.getUriForFile(
                                        this,
                                        "${applicationContext.packageName}.attachments",
                                        file,
                                    )
                                    val intent = Intent(Intent.ACTION_SEND).apply {
                                        type = mime
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    startActivity(Intent.createChooser(intent, null))
                                    result.success(null)
                                }
                            } catch (_: Exception) {
                                result.error("share_failed", null, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The Dart isolate this engine hosts is about to stop existing, so it
        // stops being the delivery owner here rather than when something
        // notices it has gone quiet.
        deliveryChannel?.let(BackgroundDelivery::detachForeground)
        deliveryChannel = null
        // A call lives in this engine's isolate too. Nothing is left to end it
        // once the engine goes, so its service ends here rather than outlive it.
        voiceCallChannel?.let(VoiceCall::detach)
        voiceCallChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Whether this activity is visible, which is what the platform asks before
    // it lets a `microphone` service start.
    override fun onStart() {
        super.onStart()
        VoiceCall.onHostVisible(this, visible = true)
    }

    override fun onStop() {
        VoiceCall.onHostVisible(this, visible = false)
        super.onStop()
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val alreadyEnabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
        if (alreadyEnabled ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            pendingNotificationPermission != null
        ) {
            // Below Android 13 there is no runtime permission to request, and a
            // second concurrent caller gets the current answer rather than a
            // second dialog and a lost reply.
            result.success(messageAlerts.platformState())
            return
        }
        pendingNotificationPermission = result
        try {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode,
            )
        } catch (_: Exception) {
            pendingNotificationPermission = null
            result.success(messageAlerts.platformState())
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (VoiceCall.onRequestPermissionsResult(this, requestCode, grantResults)) {
            return
        }
        if (requestCode != notificationPermissionRequestCode) {
            return
        }
        // The answer is read back from the notification manager rather than from
        // grantResults, which is empty when the dialog is dismissed without a
        // choice, and which says nothing about a user who has notifications
        // switched off for the whole application.
        val pending = pendingNotificationPermission
        pendingNotificationPermission = null
        pending?.success(messageAlerts.platformState())
    }

    private fun copySensitiveText(text: String, clearAfterSeconds: Int) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val label = "communication-platform-recovery"
        clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
        Handler(Looper.getMainLooper()).postDelayed({
            if (clipboard.primaryClipDescription?.label?.toString() == label) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    clipboard.clearPrimaryClip()
                } else {
                    clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                }
            }
        }, clearAfterSeconds.coerceIn(1, 300) * 1000L)
    }

    private fun safeShareMime(value: String?): String {
        val normalized = value?.trim()?.lowercase() ?: return "application/octet-stream"
        val safe = setOf(
            "image/jpeg", "image/png", "image/webp", "image/gif",
            "audio/mpeg", "audio/ogg", "audio/wav", "text/plain", "application/pdf",
        )
        return if (normalized in safe) normalized else "application/octet-stream"
    }
}
