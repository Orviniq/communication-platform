package com.example.communication_platform

import android.Manifest
import android.app.Activity
import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A call's microphone: the runtime permission a join asks for, and the
 * microphone-type foreground service that keeps the capture alive for as long
 * as the call lasts (`backend/CLIENT_CONTRACT.md` §N rule 11).
 *
 * ## Nothing here decides when
 *
 * Dart asks for the permission at the join and at no other time, starts the
 * service after a grant and before the join, and stops it when the call ends.
 * This side holds no call. It asks Android, reports the answer, starts or stops
 * one service, and shows one entry whose text Dart hands it. Nothing about the
 * room, the participants or the audio crosses the channel.
 *
 * ## The platform's limits, checked before the platform is asked
 *
 * `RECORD_AUDIO` is a while-in-use permission. From Android 14 the platform
 * throws when a `microphone` service is created without it or while the
 * application has no visible activity, and below Android 14 it creates the
 * service and gives it no microphone
 * (developer.android.com/develop/background-work/services/fgs/restrictions-bg-start,
 * read 2026-10-01). So both are checked here first and refused by name, and
 * whatever the platform refuses anyway is reported as a refusal, never as a
 * start.
 *
 * ## It ends with the call, and with the engine that holds the call
 *
 * The call lives in the Dart isolate of the activity's engine. When that engine
 * is torn down nothing is left to end the call, so [detach] stops the service
 * there; when the user removes the task, the service stops with it; and the
 * platform never restarts it.
 */
internal object VoiceCall {
    const val CHANNEL = "communication_platform/voice_call"

    /**
     * Stable for the life of the installation. The channel id keys the user's
     * own settings for this entry, so changing it would silently discard them.
     */
    const val NOTIFICATION_CHANNEL_ID = "voice-call"
    const val NOTIFICATION_ID = 3

    /**
     * The reviewed, localized text of the one entry this shows. It crosses the
     * channel with the start and travels in the start intent, for the reason
     * sustained delivery's does: the service may display only text that this
     * project wrote, and no Android string resource is a second catalogue.
     */
    const val EXTRA_TITLE = "title"
    const val EXTRA_CHANNEL_NAME = "channelName"
    const val EXTRA_CHANNEL_DESCRIPTION = "channelDescription"

    /** Distinct from the notification permission's request code, 9101. */
    const val PERMISSION_REQUEST_CODE = 9102

    // The answers that cross the channel, matched by name in
    // lib/features/voice/infrastructure/platform_voice_call_channel.dart.
    const val GRANTED = "granted"
    const val DENIED = "denied"
    const val DENIED_PERMANENTLY = "deniedPermanently"
    const val STARTED = "started"
    const val MICROPHONE_NOT_GRANTED = "microphoneNotGranted"
    const val NOT_IN_FOREGROUND = "notInForeground"
    const val REFUSED = "refused"

    /**
     * How long a start or a stop may take to land before this stops waiting.
     *
     * Starting and stopping a service are asynchronous: `onStartCommand` and
     * `onDestroy` are posted to the looper the call that asked for them runs
     * on, so neither can have run when that call returns. An answer given then
     * would report every start as a refusal. The bound sits inside the few
     * seconds the platform allows between `startForegroundService` and the
     * service reaching the foreground.
     */
    private const val TRANSITION_TIMEOUT_MS = 10_000L

    private enum class Phase { IDLE, STARTING, RUNNING, STOPPING }

    private val main = Handler(Looper.getMainLooper())

    /** The engine attached now, and the activity it belongs to. */
    private var channel: MethodChannel? = null
    private var host: Activity? = null
    private var hostVisible = false
    private var applicationContext: Context? = null

    /** The engine whose call the service runs for. */
    private var owner: MethodChannel? = null

    private val permissionWaiters = mutableListOf<MethodChannel.Result>()

    private var phase = Phase.IDLE

    /**
     * A stop arrived while the service was still on its way to the
     * foreground. Stopping it there is not allowed - the platform ends the
     * process of an application that brings down a service it started for the
     * foreground before that service called `startForeground`
     * (`ActiveServices.bringDownServiceLocked`, AOSP frameworks/base) - so it
     * stops the moment it arrives instead.
     */
    private var stopWhenStarted = false
    private val startWaiters = mutableListOf<MethodChannel.Result>()
    private val stopWaiters = mutableListOf<MethodChannel.Result>()

    private val startTimeout = Runnable {
        if (phase == Phase.STARTING) {
            // It never came up. If it does later, it stops at once rather than
            // run for a call that has been told it did not start - which is
            // also what a stop waiting on it asked for.
            stopWhenStarted = true
            answerStart(refusal(REFUSED))
            answerStop()
        }
    }

    private val stopTimeout = Runnable { answerStop() }

    // ---------------------------------------------------------------------
    // The channel, registered on the activity's engine only
    // ---------------------------------------------------------------------

    /**
     * Attaches the channel to the activity's engine. A headless engine never
     * gets it: a call needs a window, for the permission dialog and because
     * the platform starts a `microphone` service only from a visible activity.
     */
    fun attach(context: Context, messenger: BinaryMessenger, activity: Activity): MethodChannel {
        applicationContext = context.applicationContext
        host = activity
        hostVisible = false
        return MethodChannel(messenger, CHANNEL).also { attached ->
            channel = attached
            attached.setMethodCallHandler { call, result -> handle(attached, call, result) }
        }
    }

    /**
     * The engine is going away, and with it the Dart side of any call it
     * held. Nothing is left to end that call, so the service stops here: a
     * notice that a call is in progress may not outlive the call.
     */
    fun detach(detached: MethodChannel) {
        if (channel === detached) {
            channel = null
            host = null
            hostVisible = false
            // No engine is left to answer.
            permissionWaiters.clear()
        }
        if (owner === detached) {
            owner = null
            startWaiters.clear()
            stopWaiters.clear()
            applicationContext?.let { stop(it, null) }
        }
    }

    /** The activity's `onStart` and `onStop`: whether it is visible. */
    fun onHostVisible(activity: Activity, visible: Boolean) {
        if (activity === host) {
            hostVisible = visible
        }
    }

    private fun handle(requester: MethodChannel, call: MethodCall, result: MethodChannel.Result) {
        val context = applicationContext
        if (context == null) {
            result.notImplemented()
            return
        }
        when (call.method) {
            "requestMicrophone" -> requestMicrophone(context, result)
            // A check, never a request: nothing is shown.
            "microphoneGranted" -> result.success(isGranted(context))
            "openMicrophoneSettings" -> openMicrophoneSettings(context, result)
            "start" -> start(requester, context, call, result)
            "stop" -> stop(context, result)
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // The permission
    // ---------------------------------------------------------------------

    internal fun isGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestMicrophone(context: Context, result: MethodChannel.Result) {
        if (isGranted(context)) {
            // Android has nothing to ask, so nothing is shown.
            result.success(GRANTED)
            return
        }
        val activity = host
        if (activity == null) {
            // No window to host the dialog. The answer Android holds now is
            // the truthful one.
            result.success(DENIED)
            return
        }
        permissionWaiters.add(result)
        if (permissionWaiters.size > 1) {
            // A request is already in flight, and its answer is this caller's
            // too. A second dialog would only race the first.
            return
        }
        try {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                PERMISSION_REQUEST_CODE,
            )
        } catch (_: Exception) {
            settlePermission(DENIED)
        }
    }

    /**
     * The activity's `onRequestPermissionsResult`, handed on. True when the
     * answer was this channel's.
     */
    fun onRequestPermissionsResult(
        activity: Activity,
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) {
            return false
        }
        settlePermission(answer(activity, grantResults))
        return true
    }

    /**
     * Granted, denied, or denied for good.
     *
     * Android says which only through `shouldShowRequestPermissionRationale`
     * after the request. A user who refused once is flagged `USER_SET`, the
     * rationale is true, and the dialog will be shown again. A user who refused
     * twice is flagged `USER_FIXED`, the rationale is false, and "the user will
     * no longer see the system permissions dialog"
     * (developer.android.com/training/permissions/requesting, read 2026-10-01).
     * A refused request with no rationale is therefore read as permanent. The
     * one case that reads the same and is not - a first dialog dismissed
     * without an answer, if the platform reports it as a refusal; it documents
     * no way to tell the two apart - loses nothing by it: the system settings
     * allow the microphone either way, and the next join shows the dialog
     * again.
     */
    private fun answer(activity: Activity, grantResults: IntArray): String = when {
        // Read from the platform rather than from grantResults, as the
        // notification permission is.
        isGranted(activity) -> GRANTED
        // "The permissions request interaction with the user is interrupted":
        // empty arrays, "which should be treated as a cancellation"
        // (Activity.onRequestPermissionsResult). Nothing was decided.
        grantResults.isEmpty() -> DENIED
        ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.RECORD_AUDIO,
        ) -> DENIED
        else -> DENIED_PERMANENTLY
    }

    private fun settlePermission(answer: String) {
        val waiting = permissionWaiters.toList()
        permissionWaiters.clear()
        waiting.forEach { it.success(answer) }
    }

    /**
     * Opens this application's own page in the system settings, which is the
     * one place left to allow a microphone Android no longer asks for.
     *
     * Only ever in answer to the user: a join they asked for was refused for
     * good, and the screen offers this beside the reason. It is never opened on
     * its own, on a schedule or to change a mind - Android's guidance is not to
     * link there "in an effort to convince the user"
     * (developer.android.com/training/permissions/requesting, read 2026-10-01) -
     * and nothing is read back: the next join asks the platform again.
     */
    private fun openMicrophoneSettings(context: Context, result: MethodChannel.Result) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            (host ?: context).startActivity(intent)
        } catch (_: Exception) {
            // A device with no application-details screen leaves the user
            // where they were rather than ending the application.
        }
        result.success(null)
    }

    // ---------------------------------------------------------------------
    // Starting and stopping the service
    // ---------------------------------------------------------------------

    private fun start(
        requester: MethodChannel,
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (phase) {
            Phase.RUNNING -> {
                owner = requester
                result.success(started(context))
                return
            }
            Phase.STARTING -> {
                if (stopWhenStarted) {
                    result.success(refusal(REFUSED))
                } else {
                    owner = requester
                    startWaiters.add(result)
                }
                return
            }
            // The last call's service is still going away. The caller stops
            // before it starts, so this is a stop that did not land in time.
            Phase.STOPPING -> {
                result.success(refusal(REFUSED))
                return
            }
            Phase.IDLE -> Unit
        }
        if (!isGranted(context)) {
            result.success(refusal(MICROPHONE_NOT_GRANTED))
            return
        }
        if (requester !== channel || host == null || !hostVisible) {
            result.success(refusal(NOT_IN_FOREGROUND))
            return
        }
        val title = call.argument<String>(EXTRA_TITLE).orEmpty()
        val channelName = call.argument<String>(EXTRA_CHANNEL_NAME).orEmpty()
        if (title.isEmpty() || channelName.isEmpty()) {
            // A foreground service must show an entry, and one assembled here
            // would be text this project never reviewed or translated.
            result.success(refusal(REFUSED))
            return
        }
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, VoiceCallService::class.java)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_CHANNEL_NAME, channelName)
                    .putExtra(
                        EXTRA_CHANNEL_DESCRIPTION,
                        call.argument<String>(EXTRA_CHANNEL_DESCRIPTION).orEmpty(),
                    ),
            )
        } catch (e: Exception) {
            result.success(refusal(refusalFor(context, e)))
            return
        }
        phase = Phase.STARTING
        stopWhenStarted = false
        owner = requester
        startWaiters.add(result)
        main.postDelayed(startTimeout, TRANSITION_TIMEOUT_MS)
    }

    private fun stop(context: Context, result: MethodChannel.Result?) {
        when (phase) {
            Phase.IDLE -> result?.success(null)
            Phase.STARTING -> {
                stopWhenStarted = true
                result?.let(stopWaiters::add)
            }
            Phase.RUNNING -> {
                phase = Phase.STOPPING
                result?.let(stopWaiters::add)
                try {
                    context.stopService(Intent(context, VoiceCallService::class.java))
                } catch (_: Exception) {
                    // A service that cannot be stopped is not a state this
                    // process can repair. onDestroy settles the phase either way.
                }
                main.postDelayed(stopTimeout, TRANSITION_TIMEOUT_MS)
            }
            Phase.STOPPING -> result?.let(stopWaiters::add)
        }
    }

    /**
     * Why the platform refused, as far as the exception says.
     *
     * From Android 14, a `microphone` service created while the permission is
     * held but no activity is visible is a `SecurityException`: "the system
     * sees that your app doesn't currently have the required permissions".
     */
    internal fun refusalFor(context: Context, error: Exception): String = when {
        !isGranted(context) -> MICROPHONE_NOT_GRANTED
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            error is ForegroundServiceStartNotAllowedException -> NOT_IN_FOREGROUND
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            error is SecurityException -> NOT_IN_FOREGROUND
        else -> REFUSED
    }

    private fun refusal(reason: String): Map<String, Any> = mapOf("outcome" to reason)

    private fun started(context: Context): Map<String, Any> = mapOf(
        "outcome" to STARTED,
        // Read now, from the platform. With notifications off the service still
        // runs - Android shows its notice in the Task Manager instead of the
        // shade - and the screen has to be able to say so.
        "notificationVisible" to notificationVisible(context),
    )

    private fun notificationVisible(context: Context): Boolean {
        val notifications = NotificationManagerCompat.from(context)
        if (!notifications.areNotificationsEnabled()) {
            return false
        }
        val entryChannel = notifications.getNotificationChannelCompat(NOTIFICATION_CHANNEL_ID)
        return entryChannel == null ||
            entryChannel.importance != NotificationManagerCompat.IMPORTANCE_NONE
    }

    private fun answerStart(answer: Map<String, Any>) {
        val waiting = startWaiters.toList()
        startWaiters.clear()
        waiting.forEach { it.success(answer) }
    }

    private fun answerStop() {
        main.removeCallbacks(stopTimeout)
        val waiting = stopWaiters.toList()
        stopWaiters.clear()
        waiting.forEach { it.success(null) }
    }

    // ---------------------------------------------------------------------
    // What the service reports
    // ---------------------------------------------------------------------

    internal fun onServiceStarted(context: Context) {
        main.removeCallbacks(startTimeout)
        phase = Phase.RUNNING
        if (stopWhenStarted) {
            // Asked to stop on the way up, or given up on: it ends now rather
            // than run for a call nobody holds.
            stopWhenStarted = false
            answerStart(refusal(REFUSED))
            stop(context, null)
            return
        }
        answerStart(started(context))
    }

    internal fun onServiceRefused(reason: String) {
        main.removeCallbacks(startTimeout)
        // It stops itself, and onDestroy settles the phase.
        phase = Phase.STOPPING
        stopWhenStarted = false
        answerStart(refusal(reason))
    }

    internal fun onServiceStopped() {
        main.removeCallbacks(startTimeout)
        phase = Phase.IDLE
        stopWhenStarted = false
        owner = null
        // Gone before it ever started: whoever waited for it gets a refusal.
        answerStart(refusal(REFUSED))
        answerStop()
    }

    /**
     * The user removed the task. The activity goes with it, and the engine
     * the call lived in goes with the activity, so the service goes too.
     */
    internal fun onTaskRemoved(context: Context) {
        stop(context, null)
    }

    // ---------------------------------------------------------------------
    // The entry
    // ---------------------------------------------------------------------

    /**
     * The one entry the service shows for as long as the call lasts.
     *
     * Its whole content is the sentence Dart hands over, which says that a
     * call is in progress and names nobody in it: no participant, no room, no
     * count and no time. `IMPORTANCE_LOW`, silent and without vibration,
     * because it accompanies something the user chose rather than announcing
     * anything - and never `IMPORTANCE_MIN`, which hides the status-bar icon
     * that says a microphone is live. `VISIBILITY_PRIVATE` with the same
     * sentence as its public version, so a locked screen and a screen being
     * shared show the words this application chose rather than a contextless
     * redaction: whoever holds the phone learns that its microphone is live,
     * which is the one thing a live microphone owes them. Shown at once, never
     * deferred, for the same reason. The tap target is the launcher intent and
     * nothing else.
     */
    internal fun notification(context: Context, intent: Intent?): Notification? {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME).orEmpty()
        if (title.isEmpty() || channelName.isEmpty()) {
            return null
        }
        NotificationManagerCompat.from(context).createNotificationChannel(
            NotificationChannelCompat
                .Builder(NOTIFICATION_CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                .setName(channelName)
                .setDescription(intent?.getStringExtra(EXTRA_CHANNEL_DESCRIPTION).orEmpty())
                .setVibrationEnabled(false)
                .setShowBadge(false)
                .build(),
        )
        return entry(context, title)
            .setContentIntent(launchPendingIntent(context))
            .setPublicVersion(entry(context, title).build())
            .build()
    }

    private fun entry(context: Context, title: String): NotificationCompat.Builder =
        NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_call_in_progress)
            .setContentTitle(title)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setShowWhen(false)
            .setSilent(true)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

    private fun launchPendingIntent(context: Context): PendingIntent {
        val intent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}

/**
 * The microphone-type foreground service of a call.
 *
 * It holds no audio, no connection and no decision. The capture is libwebrtc's,
 * in this process; the service exists because a while-in-use permission lasts
 * only while the application is in the foreground, or while a foreground
 * service of the matching type that was started from the foreground runs. With
 * it, the call keeps the microphone while the user looks at another screen or
 * another application.
 */
class VoiceCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = VoiceCall.notification(this, intent)
        if (notification == null) {
            // No reviewed text was handed over, so there is nothing this may
            // display, so it may not run. It is a path nothing takes, and has
            // to stay one: the platform ends the process of an application
            // that stops a service started for the foreground before it gets
            // there. The channel refuses a start without text before it
            // reaches the platform, and nothing else can start an unexported
            // service that is never restarted.
            stopSelf()
            VoiceCall.onServiceRefused(VoiceCall.REFUSED)
            return START_NOT_STICKY
        }
        try {
            ServiceCompat.startForeground(
                this,
                VoiceCall.NOTIFICATION_ID,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Refused: no permission, no visible activity, or a manufacturer
            // restriction. The platform has already released its claim on the
            // start by the time it refuses, so stopping here is allowed.
            stopSelf()
            VoiceCall.onServiceRefused(VoiceCall.refusalFor(applicationContext, e))
            return START_NOT_STICKY
        }
        if (!VoiceCall.isGranted(this)) {
            // Below Android 14 the platform promotes a `microphone` service
            // without the permission, and it would hold no microphone.
            stopSelf()
            VoiceCall.onServiceRefused(VoiceCall.MICROPHONE_NOT_GRANTED)
            return START_NOT_STICKY
        }
        VoiceCall.onServiceStarted(applicationContext)
        // Never restarted. A call lives in a Dart isolate, and a process that
        // died took that isolate with it: a restarted service would announce a
        // call nobody holds.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        VoiceCall.onServiceStopped()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        VoiceCall.onTaskRemoved(applicationContext)
    }
}
