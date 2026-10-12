package com.novaplayer.nova_player

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File

/**
 * A folder the user picked through the system folder picker, searched (including
 * subfolders) for "<song file name without extension>.lrc". Only this folder is
 * readable, so no broad storage permission is needed.
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

    fun set(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
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

    fun lyricsFor(fileName: String): String? {
        val base = fileName.substringBeforeLast('.').lowercase()
        if (base.isEmpty()) return null
        val uri = indexOrBuild()[base] ?: return null
        return context.contentResolver.openInputStream(uri)?.use {
            it.readBytes().toString(Charsets.UTF_8).removePrefix("﻿")
        }
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
            indexFile.writeText(found.entries.joinToString("\n") { "${it.key}\t${it.value}" })
        }
        return found
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
                        } else if (name.endsWith(".lrc", ignoreCase = true)) {
                            found.putIfAbsent(
                                name.dropLast(4).lowercase(),
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
        runCatching {
            context.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private companion object {
        const val KEY = "tree_uri"
    }
}
