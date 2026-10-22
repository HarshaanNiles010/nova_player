package com.novaplayer.nova_player

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File

/**
 * A folder the user picked through the system folder picker, searched (including
 * subfolders) for "<song file name without extension>.lrc" and covers ".jpg". Only
 * this folder is reachable, so no broad storage permission is needed. Downloaded and
 * translated lyrics and covers are saved into it, next to the song when it is inside it.
 */
class LrcFolder(private val context: Context) {
    private val prefs = context.getSharedPreferences("nova_lyrics", Context.MODE_PRIVATE)
    private var index: Map<String, Uri>? = null

    private val treeUri: Uri?
        get() = prefs.getString(KEY, null)?.let(Uri::parse)

    /** Path inside the storage volume, e.g. "Music" for primary:Music. */
    fun displayName(): String? = treeUri?.let {
        DocumentsContract.getTreeDocumentId(it).substringAfter(':').ifEmpty { "Storage root" }
    }

    /** Whether lyrics can be saved here (folders picked before saving existed are read only). */
    fun writable(): Boolean = treeUri?.let { tree ->
        context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }
    } ?: false

    fun set(uri: Uri) {
        val readWrite = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            context.contentResolver.takePersistableUriPermission(uri, readWrite)
        } catch (_: SecurityException) {
            context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        treeUri?.takeIf { it != uri }?.let(::release)
        prefs.edit().putString(KEY, uri.toString()).apply()
        synchronized(this) {
            index = null
            indexFile.delete()
        }
    }

    fun clear() {
        treeUri?.let(::release)
        prefs.edit().remove(KEY).apply()
        synchronized(this) {
            index = null
            indexFile.delete()
        }
    }

    /** Lyrics for a song file; [suffix] ".en" finds its saved English translation. */
    fun lyricsFor(fileName: String, suffix: String = ""): String? {
        val base = fileName.substringBeforeLast('.').lowercase() + suffix
        if (base.isEmpty()) return null
        val uri = indexOrBuild()[base] ?: return null
        return context.contentResolver.openInputStream(uri)?.use {
            it.readBytes().toString(Charsets.UTF_8).removePrefix("﻿")
        }
    }

    /** A saved cover ("Song.jpg" for "Song.flac"), using the index only if it is already built. */
    fun coverFor(fileName: String): ByteArray? {
        val saved = synchronized(this) { index ?: loadSaved()?.also { index = it } } ?: return null
        val uri = saved[fileName.substringBeforeLast('.').lowercase() + ".jpg"] ?: return null
        return context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
    }

    /** Saved index, so lookups don't walk the folder (tens of seconds) each app run. */
    private val indexFile = File(context.filesDir, "lrc_index.tsv")

    /** The index from memory or disk; built only the first time. */
    fun indexOrBuild(): Map<String, Uri> {
        synchronized(this) {
            index?.let { return it }
            loadSaved()?.let { index = it; return it }
        }
        return rebuild()
    }

    /** Re-walks the folder (picks up new .lrc files); lookups keep the old index meanwhile. */
    fun rebuild(): Map<String, Uri> {
        val tree = treeUri ?: return emptyMap()
        val found = scan(tree)
        synchronized(this) {
            if (treeUri != tree) return found // folder changed mid-scan; drop the result
            index = found
            saveIndex(found)
        }
        return found
    }

    private fun saveIndex(found: Map<String, Uri>) {
        indexFile.writeText(found.entries.joinToString("\n") { "${it.key}\t${it.value}" })
    }

    /**
     * Writes [bytes] as [name] (e.g. "Song.lrc") into the song's own folder when that is
     * inside this folder, else into this folder; replaces a file of that name it already
     * indexed. False when no folder is set or it is read only.
     */
    fun save(songPath: String?, name: String, bytes: ByteArray): Boolean {
        val tree = treeUri ?: return false
        if (!writable()) return false
        val key = keyOf(name)
        val treeDoc = DocumentsContract.getTreeDocumentId(tree)
        val songDir = songPath?.let(::documentIdOf)?.substringBeforeLast('/')
        val dir = songDir?.takeIf { it == treeDoc || it.startsWith("$treeDoc/") } ?: treeDoc
        val uri = indexOrBuild()[key] ?: DocumentsContract.createDocument(
            context.contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(tree, dir),
            "application/octet-stream", // keeps the name as given
            name,
        ) ?: return false
        context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
            ?: return false
        synchronized(this) {
            val updated = (index ?: emptyMap()) + (key to uri)
            index = updated
            saveIndex(updated)
        }
        return true
    }

    /** "primary:Music/Song.flac" for /storage/emulated/0/Music/Song.flac, as document ids go. */
    private fun documentIdOf(path: String): String? {
        val primary = "/storage/emulated/0/"
        return when {
            path.startsWith(primary) -> "primary:" + path.removePrefix(primary)
            path.startsWith("/storage/") -> path.removePrefix("/storage/").let {
                "${it.substringBefore('/')}:${it.substringAfter('/')}"
            }
            else -> null
        }
    }

    private fun loadSaved(): Map<String, Uri>? {
        if (treeUri == null || !indexFile.exists()) return null
        return indexFile.readLines().mapNotNull { line ->
            val tab = line.indexOf('\t')
            if (tab < 0) null else line.substring(0, tab) to Uri.parse(line.substring(tab + 1))
        }.toMap()
    }

    private fun scan(tree: Uri): Map<String, Uri> {
        val found = HashMap<String, Uri>()
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
        )
        try {
            val pending = ArrayDeque(listOf(DocumentsContract.getTreeDocumentId(tree)))
            while (pending.isNotEmpty()) {
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, pending.removeFirst())
                context.contentResolver.query(children, columns, null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(0)
                        val name = cursor.getString(1) ?: continue
                        if (cursor.getString(2) == Document.MIME_TYPE_DIR) {
                            pending.add(id)
                        } else if (name.endsWith(".lrc", ignoreCase = true) ||
                            name.endsWith(".jpg", ignoreCase = true)
                        ) {
                            found.putIfAbsent(
                                keyOf(name),
                                DocumentsContract.buildDocumentUriUsingTree(tree, id),
                            )
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // Folder deleted or access revoked: behave as if it has no lyrics.
        }
        return found
    }

    private fun release(uri: Uri) {
        val readWrite = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { context.contentResolver.releasePersistableUriPermission(uri, readWrite) }
            .recoverCatching {
                context.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
    }

    private companion object {
        const val KEY = "tree_uri"

        /** "song" for "Song.lrc", "song.en" for "Song.en.lrc", "song.jpg" for a cover. */
        fun keyOf(name: String): String =
            if (name.endsWith(".lrc", ignoreCase = true)) name.dropLast(4).lowercase() else name.lowercase()
    }
}
