package com.novaplayer.nova_player

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Size
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** 4x1 widget: now playing and the basic controls. */
class NovaWidgetSmall : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        NovaWidgets.render(context)
}

/** Larger widget: the same controls plus recently played songs. */
class NovaWidgetLarge : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        NovaWidgets.render(context)
}

/**
 * Widget state lives in SharedPreferences so the widgets still show the last
 * song after the app is closed. The app pushes each song or play-state change.
 */
object NovaWidgets {
    private const val PREFS = "nova_widget"
    private const val RECENT_LIMIT = 5
    private val recentRows = intArrayOf(
        R.id.widget_recent_1, R.id.widget_recent_2, R.id.widget_recent_3,
        R.id.widget_recent_4, R.id.widget_recent_5
    )
    private val worker = Executors.newSingleThreadExecutor()

    fun update(
        context: Context, id: String, title: String, artist: String, uri: String, fileName: String?,
        playing: Boolean
    ) = worker.execute {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previousId = prefs.getString("id", null)
        val editor = prefs.edit().putBoolean("playing", playing)
        if (previousId != id) {
            // The song that just ended moves to the top of the recent list.
            val recent = JSONArray(prefs.getString("recent", "[]"))
            val updated = JSONArray()
            if (previousId != null) {
                updated.put(
                    JSONObject()
                        .put("id", previousId)
                        .put("title", prefs.getString("title", ""))
                        .put("artist", prefs.getString("artist", ""))
                )
            }
            for (i in 0 until recent.length()) {
                val entry = recent.getJSONObject(i)
                if (updated.length() >= RECENT_LIMIT) break
                if (entry.getString("id") != previousId && entry.getString("id") != id) updated.put(entry)
            }
            editor.putString("id", id).putString("title", title).putString("artist", artist)
                .putString("recent", updated.toString())
            saveArtwork(context, uri, fileName)
        }
        editor.apply()
        render(context)
    }

    private fun artFile(context: Context) = File(context.filesDir, "widget_art.jpg")

    private fun saveArtwork(context: Context, uri: String, fileName: String?) {
        val bitmap = try {
            val cover = LrcFolder(context).savedCover(fileName)
            if (cover != null) {
                BitmapFactory.decodeByteArray(cover, 0, cover.size)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(Uri.parse(uri), Size(300, 300), null)
            } else {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(context, Uri.parse(uri))
                    retriever.embeddedPicture?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                } finally {
                    retriever.release()
                }
            }
        } catch (_: Exception) {
            null
        }
        val file = artFile(context)
        if (bitmap == null) {
            file.delete()
            return
        }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        bitmap.recycle()
    }

    fun render(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val art = artFile(context).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }
        for ((provider, layout) in listOf(
            NovaWidgetSmall::class.java to R.layout.widget_small,
            NovaWidgetLarge::class.java to R.layout.widget_large
        )) {
            val ids = manager.getAppWidgetIds(ComponentName(context, provider))
            if (ids.isEmpty()) continue
            val views = RemoteViews(context.packageName, layout)
            bindNowPlaying(context, views, prefs, art)
            if (layout == R.layout.widget_large) bindRecent(views, prefs)
            manager.updateAppWidget(ids, views)
        }
    }

    private fun bindNowPlaying(
        context: Context, views: RemoteViews, prefs: android.content.SharedPreferences, art: Bitmap?
    ) {
        val playing = prefs.getBoolean("playing", false)
        views.setTextViewText(R.id.widget_title, prefs.getString("title", null) ?: "Nova Player")
        views.setTextViewText(R.id.widget_artist, prefs.getString("artist", null) ?: "Tap to open")
        if (art != null) {
            views.setImageViewBitmap(R.id.widget_art, art)
        } else {
            views.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
        }
        views.setImageViewResource(
            R.id.widget_play,
            if (playing) R.drawable.widget_pause else R.drawable.widget_play
        )
        views.setOnClickPendingIntent(
            R.id.widget_play,
            mediaButton(context, if (playing) KeyEvent.KEYCODE_MEDIA_PAUSE else KeyEvent.KEYCODE_MEDIA_PLAY)
        )
        views.setOnClickPendingIntent(R.id.widget_previous, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        views.setOnClickPendingIntent(R.id.widget_next, mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT))
        views.setOnClickPendingIntent(R.id.widget_info, openApp(context))
    }

    private fun bindRecent(views: RemoteViews, prefs: android.content.SharedPreferences) {
        val recent = JSONArray(prefs.getString("recent", "[]"))
        views.setViewVisibility(R.id.widget_recent_empty, if (recent.length() == 0) View.VISIBLE else View.GONE)
        recentRows.forEachIndexed { i, row ->
            if (i < recent.length()) {
                val entry = recent.getJSONObject(i)
                views.setTextViewText(row, "${entry.getString("title")}  ·  ${entry.getString("artist")}")
                views.setViewVisibility(row, View.VISIBLE)
            } else {
                views.setViewVisibility(row, View.GONE)
            }
        }
    }

    /** Sent to audio_service's receiver, the same path as headset buttons. */
    private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
            .setComponent(ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver"))
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        return PendingIntent.getBroadcast(
            context, keyCode, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )
}
