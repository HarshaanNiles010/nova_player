package com.novaplayer.nova_player

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.util.Size
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class MainActivity : AudioServiceActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private val lrcFolder by lazy { LrcFolder(this) }
    private val musicFolders by lazy { MusicFolders(this) }
    private var pendingMusicFolderResult: MethodChannel.Result? = null
    // Backup and playlist files: the result and, when saving, the text to write.
    private var pendingFile: Pair<MethodChannel.Result, String?>? = null

    // Library scans read many files; keep them off the UI thread and in order.
    private val libraryExecutor = Executors.newSingleThreadExecutor()
    // Newest request first: after a fast scroll the tiles on screen asked last,
    // so they must not wait behind thousands of requests for tiles already gone.
    private val artworkExecutor = newestFirstExecutor(2)
    // Separate pool: building the .lrc folder index can take seconds and must
    // not hold up cover art.
    private val lyricsExecutor = newestFirstExecutor(1)

    private fun newestFirstExecutor(threads: Int) = ThreadPoolExecutor(
        threads, threads, 0, TimeUnit.MILLISECONDS,
        object : LinkedBlockingDeque<Runnable>() {
            override fun offer(e: Runnable) = offerFirst(e)
        }
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.novaplayer/music_library"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSongs" -> loadSongs(result)
                "getLyrics" -> loadLyrics(
                    call.argument<String>("uri"),
                    call.argument<String>("fileName"),
                    result
                )
                "getLyricsFolder" -> result.success(
                    lrcFolder.displayName()?.let { if (lrcFolder.writable()) it else "$it (read only)" }
                )
                "getStoredTranslation" -> {
                    val fileName = call.argument<String>("fileName")
                    lyricsExecutor.execute {
                        val text = runCatching { fileName?.let { lrcFolder.lyricsFor(it, ".en") } }.getOrNull()
                        runOnUiThread { result.success(text) }
                    }
                }
                "saveLyrics" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    lyricsExecutor.execute {
                        val saved = runCatching { lrcFolder.save(path, name, text.toByteArray()) }.getOrDefault(false)
                        runOnUiThread { result.success(saved) }
                    }
                }
                "getCovers" -> lyricsExecutor.execute {
                    val covers = lrcFolder.allCovers()
                    runOnUiThread { result.success(covers) }
                }
                "deleteCover" -> {
                    val name = call.argument<String>("name") ?: ""
                    lyricsExecutor.execute {
                        val deleted = runCatching { lrcFolder.delete(name) }.getOrDefault(false)
                        runOnUiThread { result.success(deleted) }
                    }
                }
                "saveCover" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: ""
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    lyricsExecutor.execute {
                        val saved = runCatching { lrcFolder.save(path, name, bytes) }.getOrDefault(false)
                        runOnUiThread { result.success(saved) }
                    }
                }
                "getFilesDir" -> result.success(filesDir.absolutePath)
                "getMusicFolders" -> result.success(musicFolders.list())
                "addMusicFolder" -> addMusicFolder(result)
                "removeMusicFolder" -> {
                    call.argument<String>("uri")?.let(musicFolders::remove)
                    result.success(null)
                }
                "rescanStorage" -> rescanStorage(result)
                "saveTextFile" -> pickFile(
                    Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(call.argument<String>("mimeType") ?: "text/plain")
                        .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name")),
                    call.argument<String>("text") ?: "",
                    result
                )
                "openTextFile" -> pickFile(
                    Intent(Intent.ACTION_OPEN_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType("*/*"),
                    null,
                    result
                )
                "restartApp" -> {
                    // Restored settings are read at start-up, so start fresh.
                    packageManager.getLaunchIntentForPackage(packageName)?.let {
                        startActivity(
                            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        )
                    }
                    android.os.Process.killProcess(android.os.Process.myPid())
                }
                "updateWidget" -> {
                    NovaWidgets.update(
                        applicationContext,
                        call.argument<String>("id") ?: "",
                        call.argument<String>("title") ?: "",
                        call.argument<String>("artist") ?: "",
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("fileName"),
                        call.argument<Boolean>("playing") ?: false
                    )
                    result.success(null)
                }
                "pickLyricsFolder" -> pickLyricsFolder(result)
                "clearLyricsFolder" -> {
                    lrcFolder.clear()
                    result.success(null)
                }
                "getArtwork" -> loadArtwork(
                    call.argument<String>("uri"),
                    call.argument<String>("fileName"),
                    call.argument<Int>("size"),
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun loadArtwork(uriText: String?, fileName: String?, size: Int?, result: MethodChannel.Result) {
        if (uriText.isNullOrBlank()) {
            result.error("INVALID_URI", "A song URI is required", null)
            return
        }
        artworkExecutor.execute {
            // A saved cover wins over the embedded one, which may be missing or wrong.
            lrcFolder.savedCover(fileName)?.let { cover ->
                val bytes = if (size == null) cover else thumbnail(cover, size)
                if (bytes != null) {
                    runOnUiThread { result.success(bytes) }
                    return@execute
                }
            }
            if (size != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // MediaStore caches thumbnails on disk, far cheaper than re-reading the file.
                val thumbnail = try {
                    contentResolver.loadThumbnail(Uri.parse(uriText), Size(size, size), null)
                } catch (_: Exception) {
                    null
                }
                if (thumbnail != null) {
                    val bytes = ByteArrayOutputStream().use { out ->
                        thumbnail.compress(Bitmap.CompressFormat.JPEG, 85, out)
                        thumbnail.recycle()
                        out.toByteArray()
                    }
                    runOnUiThread { result.success(bytes) }
                    return@execute
                }
            }
            val retriever = MediaMetadataRetriever()
            val artwork = try {
                retriever.setDataSource(this, Uri.parse(uriText))
                retriever.embeddedPicture?.let { if (size == null) it else thumbnail(it, size) }
            } catch (_: Exception) {
                null
            } finally {
                retriever.release()
            }
            runOnUiThread { result.success(artwork) }
        }
    }

    private fun pickLyricsFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("REQUEST_IN_PROGRESS", "Folder picker already open", null)
            return
        }
        pendingFolderResult = result
        @Suppress("DEPRECATION") // FlutterActivity has no ActivityResult registry to hook into.
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), LYRICS_FOLDER_REQUEST)
    }

    private fun addMusicFolder(result: MethodChannel.Result) {
        if (pendingMusicFolderResult != null) {
            result.error("REQUEST_IN_PROGRESS", "Folder picker already open", null)
            return
        }
        pendingMusicFolderResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), MUSIC_FOLDER_REQUEST)
    }

    /** Opens Android's file picker; saves [text] to the picked file, or reads it when null. */
    private fun pickFile(intent: Intent, text: String?, result: MethodChannel.Result) {
        if (pendingFile != null) {
            result.error("REQUEST_IN_PROGRESS", "File picker already open", null)
            return
        }
        pendingFile = result to text
        @Suppress("DEPRECATION")
        startActivityForResult(intent, FILE_REQUEST)
    }

    /** Asks Android's media scanner to re-index every storage volume, then reports back. */
    private fun rescanStorage(result: MethodChannel.Result) {
        val roots = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            getSystemService(StorageManager::class.java).storageVolumes
                .mapNotNull { it.directory?.absolutePath }
        } else {
            @Suppress("DEPRECATION")
            listOf(Environment.getExternalStorageDirectory().absolutePath)
        }
        libraryExecutor.execute {
            val done = CountDownLatch(roots.size)
            MediaScannerConnection.scanFile(this, roots.toTypedArray(), null) { _, _ -> done.countDown() }
            // shortcut: give up waiting after 3 minutes; the scan keeps going in the background.
            done.await(3, TimeUnit.MINUTES)
            runOnUiThread { result.success(null) }
        }
        // Own thread: the walk takes tens of seconds and must not delay the song reload.
        Thread { lrcFolder.rebuild() }.start() // new .lrc files show after a rescan
    }

    @Deprecated("Deprecated in Android; still the FlutterActivity callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FILE_REQUEST) {
            val (result, text) = pendingFile ?: return
            pendingFile = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                result.success(null) // cancelled
                return
            }
            libraryExecutor.execute {
                try {
                    val answer = if (text != null) {
                        contentResolver.openOutputStream(uri, "wt")!!.use { it.write(text.toByteArray()) }
                        "saved"
                    } else {
                        contentResolver.openInputStream(uri)!!.use { it.readBytes().toString(Charsets.UTF_8) }
                    }
                    runOnUiThread { result.success(answer) }
                } catch (error: Exception) {
                    runOnUiThread { result.error("FILE_ERROR", error.message, null) }
                }
            }
            return
        }
        if (requestCode == MUSIC_FOLDER_REQUEST) {
            val result = pendingMusicFolderResult ?: return
            pendingMusicFolderResult = null
            val uri = data?.data
            try {
                if (resultCode == RESULT_OK && uri != null) musicFolders.add(uri)
                result.success(resultCode == RESULT_OK && uri != null)
            } catch (error: SecurityException) {
                result.error("PERMISSION_DENIED", error.message, null)
            }
            return
        }
        if (requestCode != LYRICS_FOLDER_REQUEST) return
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(lrcFolder.displayName()) // cancelled: keep the old folder
            return
        }
        try {
            lrcFolder.set(uri)
            lyricsExecutor.execute { lrcFolder.rebuild() } // build the new folder's index
            result.success(lrcFolder.displayName())
        } catch (error: SecurityException) {
            result.error("PERMISSION_DENIED", error.message, null)
        }
    }

    private fun loadLyrics(uriText: String?, fileName: String?, result: MethodChannel.Result) {
        if (uriText.isNullOrBlank()) {
            result.error("INVALID_URI", "A song URI is required", null)
            return
        }
        lyricsExecutor.execute {
            val embedded = try {
                contentResolver.openInputStream(Uri.parse(uriText))?.use(LyricsReader::read)
            } catch (_: Exception) {
                null
            }
            val lyrics = embedded?.takeIf { it.isNotBlank() } ?: try {
                fileName?.let(lrcFolder::lyricsFor)
            } catch (_: Exception) {
                null
            }
            runOnUiThread { result.success(lyrics) }
        }
    }

    private fun thumbnail(bytes: ByteArray, size: Int): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }

    private fun loadSongs(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(requiredPermission()) == PackageManager.PERMISSION_GRANTED
        ) {
            querySongs(result)
            return
        }
        if (pendingResult != null) {
            result.error("REQUEST_IN_PROGRESS", "Audio permission request already in progress", null)
            return
        }
        pendingResult = result
        requestPermissions(arrayOf(requiredPermission()), AUDIO_PERMISSION_REQUEST)
    }

    private fun requiredPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != AUDIO_PERMISSION_REQUEST) return
        val result = pendingResult ?: return
        pendingResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            querySongs(result)
        } else {
            result.error("PERMISSION_DENIED", "Audio permission was denied", null)
        }
    }

    private fun querySongs(result: MethodChannel.Result) {
        val projection = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.YEAR,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATE_ADDED
        )
        // The genre column only exists on Android 11+.
        val hasGenre = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        if (hasGenre) projection += MediaStore.Audio.Media.GENRE
        // The file path (deprecated for writing, still filled in for reading),
        // and its folder: RELATIVE_PATH from Android 10, else from the path.
        @Suppress("DEPRECATION")
        projection += MediaStore.Audio.Media.DATA
        val hasRelativePath = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        if (hasRelativePath) projection += MediaStore.Audio.Media.RELATIVE_PATH
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND " +
            "${MediaStore.Audio.Media.DURATION} > 0"

        libraryExecutor.execute {
        try {
            val songs = mutableListOf<Map<String, Any?>>()
            val indexed = HashSet<Pair<String, Long>>()
            contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                projection.toTypedArray(),
                selection,
                null,
                "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC"
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durationIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val fileNameIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
                val mimeTypeIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
                val yearIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.YEAR)
                val sizeIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
                val addedIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
                val genreIndex =
                    if (hasGenre) cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.GENRE) else -1
                @Suppress("DEPRECATION")
                val pathIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                val relativePathIndex =
                    if (hasRelativePath) cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.RELATIVE_PATH) else -1

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idIndex)
                    indexed += (cursor.getString(fileNameIndex) ?: "") to cursor.getLong(sizeIndex)
                    songs += mapOf(
                        "id" to id.toString(),
                        "title" to cursor.getString(titleIndex),
                        "artist" to cursor.getString(artistIndex),
                        "album" to cursor.getString(albumIndex),
                        "duration" to cursor.getLong(durationIndex),
                        "fileName" to cursor.getString(fileNameIndex),
                        "mimeType" to cursor.getString(mimeTypeIndex),
                        "year" to cursor.getInt(yearIndex),
                        "genre" to if (genreIndex >= 0) cursor.getString(genreIndex) else null,
                        "dateAdded" to cursor.getLong(addedIndex) * 1000, // seconds to ms
                        "size" to cursor.getLong(sizeIndex),
                        "path" to cursor.getString(pathIndex),
                        "folder" to if (relativePathIndex >= 0) {
                            (cursor.getString(relativePathIndex) ?: "").trimEnd('/')
                        } else {
                            (cursor.getString(pathIndex) ?: "").substringBeforeLast('/', "")
                        },
                        "uri" to ContentUris.withAppendedId(
                            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                            id
                        ).toString()
                    )
                }
            }
            val extra = musicFolders.scan { name, size -> (name to size) in indexed }
            if (extra.isNotEmpty()) {
                songs += extra
                songs.sortBy { (it["title"] as? String)?.lowercase() ?: "" }
            }
            runOnUiThread { result.success(songs) }
        } catch (error: SecurityException) {
            runOnUiThread { result.error("PERMISSION_DENIED", error.message, null) }
        } catch (error: Exception) {
            runOnUiThread { result.error("LIBRARY_ERROR", error.message, null) }
        }
        }
    }

    companion object {
        private const val AUDIO_PERMISSION_REQUEST = 1001
        private const val LYRICS_FOLDER_REQUEST = 1002
        private const val MUSIC_FOLDER_REQUEST = 1003
        private const val FILE_REQUEST = 1004
    }
}
