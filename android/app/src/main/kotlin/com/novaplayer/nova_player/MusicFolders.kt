package com.novaplayer.nova_player

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import org.json.JSONObject
import java.io.File

/**
 * Extra music folders the user picked (Storage Access Framework). Their audio files
 * are read directly, so this also covers folders Android's media index skips
 * (e.g. ones containing .nomedia). Tags are cached by file, so rescans stay fast.
 */
class MusicFolders(private val context: Context) {
    private val prefs = context.getSharedPreferences("nova_music_folders", Context.MODE_PRIVATE)
    private val cacheFile = File(context.filesDir, "music_folder_cache.json")

    private val trees: Set<String>
        get() = prefs.getStringSet(KEY, emptySet()) ?: emptySet()

    fun list(): List<Map<String, String>> = trees.sorted().map {
        mapOf("uri" to it, "name" to displayName(Uri.parse(it)))
    }

    fun add(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        prefs.edit().putStringSet(KEY, trees + uri.toString()).apply()
    }

    fun remove(uriText: String) {
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(uriText),
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        prefs.edit().putStringSet(KEY, trees - uriText).apply()
    }

    /** Songs in every folder, skipping files [alreadyIndexed] (name, size) reports as known. */
    fun scan(alreadyIndexed: (name: String, size: Long) -> Boolean): List<Map<String, Any?>> {
        val oldCache = readCache()
        val newCache = JSONObject()
        val songs = mutableListOf<Map<String, Any?>>()
        for (treeText in trees) {
            val tree = Uri.parse(treeText)
            walk(tree) { docId, name, mime, modified, size ->
                if (!isAudio(name, mime) || alreadyIndexed(name, size)) return@walk
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
                val key = uri.toString()
                val cached = oldCache.optJSONObject(key)
                    ?.takeIf { it.optLong("m") == modified && it.optLong("s") == size }
                val tags = cached ?: readTags(uri, modified, size) ?: return@walk
                newCache.put(key, tags)
                songs += mapOf(
                    "id" to "doc:$key",
                    "title" to tags.optString("title").ifBlank { name.substringBeforeLast('.') },
                    "artist" to tags.optString("artist"),
                    "album" to tags.optString("album"),
                    "duration" to tags.optLong("duration"),
                    "fileName" to name,
                    "mimeType" to mime,
                    "year" to tags.optString("year").take(4).toIntOrNull(),
                    "genre" to tags.optString("genre"),
                    "dateAdded" to modified, // SAF has no added date; last modified is closest
                    "size" to size,
                    // Document ids look like "primary:Music/Album/song.flac"
                    // or "3738-3432:Music/song.flac" for an SD card.
                    "folder" to docId.substringAfter(':').substringBeforeLast('/', ""),
                    "path" to docId.substringBefore(':').let { volume ->
                        val root = if (volume == "primary") "/storage/emulated/0" else "/storage/$volume"
                        "$root/${docId.substringAfter(':')}"
                    },
                    "uri" to key,
                )
            }
        }
        runCatching { cacheFile.writeText(newCache.toString()) }
        return songs
    }

    private fun walk(tree: Uri, visit: (String, String, String, Long, Long) -> Unit) {
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_SIZE,
        )
        try {
            val pending = ArrayDeque(listOf(DocumentsContract.getTreeDocumentId(tree)))
            while (pending.isNotEmpty()) {
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, pending.removeFirst())
                context.contentResolver.query(children, columns, null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(0)
                        val name = cursor.getString(1) ?: continue
                        val mime = cursor.getString(2) ?: ""
                        if (mime == Document.MIME_TYPE_DIR) {
                            pending.add(id)
                        } else {
                            visit(id, name, mime, cursor.getLong(3), cursor.getLong(4))
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // Folder removed or access revoked: it simply contributes no songs.
        }
    }

    private fun readTags(uri: Uri, modified: Long, size: Long): JSONObject? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            if (duration <= 0L) return null // not playable audio
            JSONObject()
                .put("m", modified)
                .put("s", size)
                .put("title", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE))
                .put("artist", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST))
                .put("album", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM))
                .put("genre", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_GENRE))
                .put("year", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_YEAR))
                .put("duration", duration)
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun readCache(): JSONObject =
        runCatching { JSONObject(cacheFile.readText()) }.getOrDefault(JSONObject())

    private fun isAudio(name: String, mime: String) =
        mime.startsWith("audio/") || name.substringAfterLast('.', "").lowercase() in AUDIO_EXTENSIONS

    private fun displayName(tree: Uri): String =
        DocumentsContract.getTreeDocumentId(tree).let { id ->
            val volume = id.substringBefore(':')
            val path = id.substringAfter(':').ifEmpty { "(root)" }
            if (volume == "primary") "Internal storage/$path" else "SD card/$path"
        }

    private companion object {
        const val KEY = "trees"
        val AUDIO_EXTENSIONS = setOf("flac", "mp3", "opus", "ogg", "oga", "m4a", "aac", "wav", "wma", "alac")
    }
}
