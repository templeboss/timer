package com.example.timer_app

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.media.MediaPlayer
import android.os.Build
import android.util.Log
import java.io.File
import android.os.Handler
import android.os.Looper
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.session.MediaButtonReceiver

object AlarmNotificationHelper {
    const val CHANNEL_ID = "alarm_channel"
    const val NOTIFICATION_ID = 1
    const val ACTION_DISMISS = "DISMISS_ALARM"

    // internal so AlarmMediaBrowserService can read the token
    internal var mediaSession: MediaSessionCompat? = null

    // Explicit guard flag — more reliable than mediaSession?.isActive which can be
    // cleared by external events (e.g. system deactivating the session) between two
    // show() calls dispatched from different Flutter engines.
    private var isAlarmShowing = false

    // Stored as Any? to avoid API-level field declaration issues;
    // cast to AudioManager.AudioPlaybackCallback where used (API 26+).
    private var playbackCallback: Any? = null

    private var mediaPlayer: MediaPlayer? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null

    fun show(context: Context, timerName: String, playSound: Boolean = false) {
        Log.d("AlarmHelper", "show: timerName=$timerName playSound=$playSound isAlarmShowing=$isAlarmShowing")
        // Guard against double-invocation (background task + main isolate can both call show()
        // for the same alarm when the app receives the MQTT wasElapsed update).
        if (isAlarmShowing) {
            Log.d("AlarmHelper", "show: alarm already active, ignoring duplicate call")
            return
        }
        isAlarmShowing = true
        val appContext = context.applicationContext

        val dismissIntent = Intent(context, DismissAlarmReceiver::class.java).apply {
            action = ACTION_DISMISS
        }
        val dismissPi = PendingIntent.getBroadcast(
            context, 0, dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openPi = PendingIntent.getActivity(
            context, 1, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // PendingIntent pointing to the manifest MediaButtonReceiver so Android
        // knows where to deliver button events for this session.
        val mediaButtonIntent = Intent(appContext, MediaButtonReceiver::class.java)
        val mediaButtonPi = PendingIntent.getBroadcast(
            appContext, 0, mediaButtonIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        mediaSession?.release()
        mediaSession = MediaSessionCompat(appContext, "AlarmSession").also { s ->
            s.setMediaButtonReceiver(mediaButtonPi)
            s.setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay()  = sendDismiss(appContext)
                override fun onPause() = sendDismiss(appContext)
                override fun onStop()  = sendDismiss(appContext)
            }, Handler(Looper.getMainLooper()))
            s.setPlaybackState(
                PlaybackStateCompat.Builder()
                    .setActions(
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_STOP
                    )
                    .setState(
                        PlaybackStateCompat.STATE_PLAYING,
                        PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                        1f
                    )
                    .build()
            )
            s.isActive = true
        }

        appContext.startService(Intent(appContext, AlarmMediaBrowserService::class.java))

        if (playSound) {
            startNativeAudio(appContext)
        }

        // Delay registering the playback watcher so audioplayers has time to
        // claim audio focus first — otherwise Spotify (still STARTED before
        // it pauses due to focus loss) would trigger an immediate dismiss.
        Handler(Looper.getMainLooper()).postDelayed({
            if (mediaSession != null) registerPlaybackWatcher(appContext)
        }, 1500)

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(timerName)
            .setContentText("Timer elapsed")
            .setContentIntent(openPi)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSound(null)
            .setVibrate(longArrayOf(0, 300, 200, 300))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .addAction(0, "Dismiss", dismissPi)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notification)
    }

    private fun startNativeAudio(context: Context) {
        Log.d("AlarmHelper", "startNativeAudio: begin")
        stopNativeAudio(context)
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // We hold focus only to assert priority; we don't dismiss on loss.
        // Headset-button dismiss is handled by MediaSession callbacks and
        // registerPlaybackWatcher — the focus-loss path fires too eagerly
        // (e.g. when the main isolate's audioplayers briefly requests focus).
        val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
            Log.d("AlarmHelper", "audioFocusChange: $change (ignored)")
        }

        val granted: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build())
                .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                .build()
            audioFocusRequest = req
            granted = am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            granted = am.requestAudioFocus(
                focusListener, AudioManager.STREAM_ALARM, AudioManager.AUDIOFOCUS_GAIN
            )
            legacyFocusListener = focusListener
        }

        Log.d("AlarmHelper", "audioFocus granted=$granted (expected ${AudioManager.AUDIOFOCUS_REQUEST_GRANTED})")
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            Log.e("AlarmHelper", "audio focus NOT granted — aborting")
            return
        }

        val soundPath = extractDefaultSound(context)
        Log.d("AlarmHelper", "soundPath=$soundPath")
        if (soundPath == null) {
            Log.e("AlarmHelper", "extractDefaultSound returned null — aborting")
            return
        }
        try {
            val player = MediaPlayer()
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            player.setDataSource(soundPath)
            player.isLooping = true
            player.prepare()
            player.start()
            mediaPlayer = player
            Log.d("AlarmHelper", "MediaPlayer started successfully")
        } catch (e: Exception) {
            Log.e("AlarmHelper", "MediaPlayer failed: ${e.message}", e)
        }
    }

    // Flutter compresses assets in the APK, so openFd() fails for .wav files.
    // Copy via InputStream to the cache dir instead, which works regardless of compression.
    private fun extractDefaultSound(context: Context): String? {
        return try {
            val outFile = File(context.cacheDir, "work_timer_alarm.wav")
            Log.d("AlarmHelper", "extractDefaultSound: outFile=${outFile.absolutePath} exists=${outFile.exists()} size=${if (outFile.exists()) outFile.length() else 0}")
            if (!outFile.exists()) {
                Log.d("AlarmHelper", "extractDefaultSound: copying from assets")
                context.assets.open("flutter_assets/default.wav").use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
                Log.d("AlarmHelper", "extractDefaultSound: copied, size=${outFile.length()}")
            }
            outFile.absolutePath
        } catch (e: Exception) {
            Log.e("AlarmHelper", "extractDefaultSound failed: ${e.message}", e)
            null
        }
    }

    private fun stopNativeAudio(context: Context) {
        try {
            mediaPlayer?.run { if (isPlaying) stop(); release() }
        } catch (_: Exception) {}
        mediaPlayer = null

        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            legacyFocusListener?.let { am.abandonAudioFocus(it) }
            legacyFocusListener = null
        }
    }

    /**
     * Watch for any USAGE_MEDIA/USAGE_GAME player becoming active.
     * When that happens (e.g. Spotify resuming via headset button), dismiss the alarm.
     * Only registered on API 26+ where AudioPlaybackCallback is available.
     */
    private fun registerPlaybackWatcher(appContext: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        unregisterPlaybackWatcher(appContext)

        val cb = object : AudioManager.AudioPlaybackCallback() {
            override fun onPlaybackConfigChanged(configs: List<AudioPlaybackConfiguration>) {
                val hasMediaPlaying = configs.any { cfg ->
                    cfg.audioAttributes.usage == AudioAttributes.USAGE_MEDIA ||
                    cfg.audioAttributes.usage == AudioAttributes.USAGE_GAME
                }
                if (hasMediaPlaying && mediaSession != null) {
                    am.unregisterAudioPlaybackCallback(this)
                    playbackCallback = null
                    sendDismiss(appContext)
                }
            }
        }
        playbackCallback = cb
        am.registerAudioPlaybackCallback(cb, Handler(Looper.getMainLooper()))
    }

    private fun unregisterPlaybackWatcher(appContext: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        @Suppress("UNCHECKED_CAST")
        (playbackCallback as? AudioManager.AudioPlaybackCallback)
            ?.let { am.unregisterAudioPlaybackCallback(it) }
        playbackCallback = null
    }

    fun cancel(context: Context) {
        Log.d("AlarmHelper", "cancel: called")
        isAlarmShowing = false
        unregisterPlaybackWatcher(context.applicationContext)
        stopNativeAudio(context.applicationContext)

        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null

        context.applicationContext.stopService(
            Intent(context.applicationContext, AlarmMediaBrowserService::class.java)
        )

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
    }

    private fun sendDismiss(context: Context) {
        val intent = Intent(context, DismissAlarmReceiver::class.java).apply {
            action = ACTION_DISMISS
        }
        context.sendBroadcast(intent)
    }
}
