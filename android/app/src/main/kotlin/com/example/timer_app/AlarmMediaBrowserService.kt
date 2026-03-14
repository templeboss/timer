package com.example.timer_app

import android.content.Intent
import android.os.Bundle
import android.support.v4.media.MediaBrowserCompat
import androidx.media.MediaBrowserServiceCompat
import androidx.media.session.MediaButtonReceiver

class AlarmMediaBrowserService : MediaBrowserServiceCompat() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        AlarmNotificationHelper.mediaSession?.let { session ->
            sessionToken = session.sessionToken
            // Forward media button intents (e.g. from a Bluetooth headset) to
            // the session so onPlay/onPause/onStop callbacks fire.
            MediaButtonReceiver.handleIntent(session, intent)
        }
        return START_NOT_STICKY
    }

    override fun onGetRoot(
        clientPackageName: String,
        clientUid: Int,
        rootHints: Bundle?
    ): BrowserRoot = BrowserRoot("__alarm_root__", null)

    override fun onLoadChildren(
        parentId: String,
        result: Result<MutableList<MediaBrowserCompat.MediaItem>>
    ) {
        result.sendResult(mutableListOf())
    }
}
