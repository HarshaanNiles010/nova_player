package com.novaplayer.nova_player

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.nio.charset.Charset

/**
 * Reads embedded lyrics without decoding audio: Vorbis comments (FLAC, Ogg Opus/Vorbis),
 * ID3v2.3/2.4 USLT or TXXX frames (MP3) and the iTunes ©lyr atom (M4A).
 * Returns the raw text, often LRC. [readTags] reads other text tags the same way.
 */
object LyricsReader {
    private val lyricKeys = setOf("LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "USLT")

    // Tags can hold large cover art; give up rather than buffer an absurd amount.
    private const val MAX_TAG_BYTES = 32 * 1024 * 1024

    fun read(input: InputStream): String? = readTags(input, lyricKeys).values.firstOrNull()

    /** The text tags named in [keys] (upper case), in file order; empty when there are none. */
    fun readTags(input: InputStream, keys: Set<String>): Map<String, String> = try {
        val data = DataInputStream(input.buffered())
        val magic = ByteArray(4)
        data.readFully(magic)
        when {
            magic.startsWith("fLaC") -> readFlac(data, keys)
            magic.startsWith("OggS") -> readOgg(data, keys)
            magic.startsWith("ID3") -> readId3(data, magic[3].toInt(), keys)
            else -> {
                val type = ByteArray(4)
                data.readFully(type)
                if (type.startsWith("ftyp")) readMp4(data, int(magic, 0).toLong(), keys) else emptyMap()
            }
        }
    } catch (_: EOFException) {
        emptyMap()
    }

    private fun readFlac(data: DataInputStream, keys: Set<String>): Map<String, String> {
        while (true) {
            val header = data.readUnsignedByte()
            val length = (data.readUnsignedByte() shl 16) or
                (data.readUnsignedByte() shl 8) or data.readUnsignedByte()
            if (header and 0x7F == 4) {
                val block = ByteArray(length)
                data.readFully(block)
                return vorbisTags(block, 0, keys)
            }
            data.skipFully(length)
            if (header and 0x80 != 0) return emptyMap()
        }
    }

    /** The comment header is the second Ogg packet; it may span several pages. */
    private fun readOgg(data: DataInputStream, keys: Set<String>): Map<String, String> {
        var packetIndex = 0
        val packet = ByteArrayOutputStream()
        var magicRead = true
        while (true) {
            if (!magicRead) {
                val magic = ByteArray(4)
                data.readFully(magic)
                if (!magic.startsWith("OggS")) return emptyMap()
            }
            magicRead = false
            data.skipFully(22) // version, type, granule, serial, sequence, CRC
            val lacing = IntArray(data.readUnsignedByte()) { data.readUnsignedByte() }
            for (size in lacing) {
                if (packetIndex == 1) {
                    val chunk = ByteArray(size)
                    data.readFully(chunk)
                    packet.write(chunk)
                    if (packet.size() > MAX_TAG_BYTES) return emptyMap()
                } else {
                    data.skipFully(size)
                }
                if (size < 255) {
                    if (packetIndex == 1) {
                        val bytes = packet.toByteArray()
                        return when {
                            bytes.startsWith("OpusTags") -> vorbisTags(bytes, 8, keys)
                            bytes.size > 7 && bytes[0] == 3.toByte() &&
                                bytes.startsWith("vorbis", 1) -> vorbisTags(bytes, 7, keys)
                            else -> emptyMap()
                        }
                    }
                    packetIndex++
                }
            }
        }
    }

    /** Walks top-level atoms (skipping the audio) until moov, then reads udta/meta/ilst. */
    private fun readMp4(data: DataInputStream, ftypSize: Long, keys: Set<String>): Map<String, String> {
        data.skipFully(ftypSize - 8)
        while (true) {
            var size = data.readInt().toLong() and 0xFFFFFFFFL
            val type = ByteArray(4)
            data.readFully(type)
            var header = 8L
            if (size == 1L) {
                size = data.readLong()
                header = 16L
            }
            if (size == 0L) return emptyMap() // last atom runs to end of file and is not moov
            if (size < header) return emptyMap()
            if (!type.startsWith("moov")) {
                data.skipFully(size - header)
                continue
            }
            if (size - header > MAX_TAG_BYTES) return emptyMap()
            val moov = ByteArray((size - header).toInt())
            data.readFully(moov)
            val (start, end) = findAtom(moov, 0, moov.size, listOf("udta", "meta", "ilst"))
                ?: return emptyMap()
            val tags = linkedMapOf<String, String>()
            if ("LYRICS" in keys) {
                mp4Text(moov, start, end, "\u00A9lyr")?.let { tags["LYRICS"] = it }
            }
            // Freeform "----" atoms hold tags like replaygain_track_gain.
            var p = start
            while (p + 8 <= end) {
                val atomSize = int(moov, p)
                if (atomSize < 8 || p + atomSize > end) break
                if (String(moov, p + 4, 4, Charsets.ISO_8859_1) == "----") {
                    val name = findAtom(moov, p + 8, p + atomSize, listOf("name"))
                    // name atom body: 4 bytes of version/flags, then the text.
                    val key = name?.takeIf { it.second - it.first > 4 }?.let {
                        String(moov, it.first + 4, it.second - it.first - 4, Charsets.UTF_8).uppercase()
                    }
                    if (key in keys) {
                        mp4Text(moov, p + 8, p + atomSize, null)?.let { tags[key!!] = it }
                    }
                }
                p += atomSize
            }
            return tags
        }
    }

    /** The text of a data atom, inside [parent] when given. */
    private fun mp4Text(b: ByteArray, start: Int, end: Int, parent: String?): String? {
        val (from, to) = findAtom(b, start, end, listOfNotNull(parent, "data")) ?: return null
        // data atom body: 4-byte type, 4-byte locale, then UTF-8 text.
        return if (to - from < 8) null else String(b, from + 8, to - from - 8, Charsets.UTF_8)
    }

    private fun findAtom(b: ByteArray, start: Int, end: Int, path: List<String>): Pair<Int, Int>? {
        var p = start
        while (p + 8 <= end) {
            var size = int(b, p).toLong() and 0xFFFFFFFFL
            var header = 8
            if (size == 1L) {
                if (p + 16 > end) return null
                size = (int(b, p + 8).toLong() shl 32) or (int(b, p + 12).toLong() and 0xFFFFFFFFL)
                header = 16
            } else if (size == 0L) {
                size = (end - p).toLong()
            }
            if (size < header || p + size > end) return null
            val atomEnd = (p + size).toInt()
            if (String(b, p + 4, 4, Charsets.ISO_8859_1) == path[0]) {
                // meta is a "full box": 4 bytes of version/flags precede its children.
                val body = p + header + if (path[0] == "meta") 4 else 0
                return if (path.size == 1) body to atomEnd else findAtom(b, body, atomEnd, path.drop(1))
            }
            p = atomEnd
        }
        return null
    }

    private fun vorbisTags(b: ByteArray, start: Int, keys: Set<String>): Map<String, String> {
        val tags = linkedMapOf<String, String>()
        var p = start
        fun u32(): Int {
            if (p + 4 > b.size) throw EOFException()
            val value = (b[p].toInt() and 0xFF) or ((b[p + 1].toInt() and 0xFF) shl 8) or
                ((b[p + 2].toInt() and 0xFF) shl 16) or ((b[p + 3].toInt() and 0xFF) shl 24)
            p += 4
            return value
        }
        val vendorLength = u32() // separate statement: `p += u32()` would read p before u32 moves it
        p += vendorLength
        repeat(u32()) {
            val length = u32()
            if (length < 0 || p + length > b.size) return tags
            // Only decode the key; picture comments can be megabytes long.
            val equals = (p until p + minOf(length, 64)).firstOrNull { b[it] == '='.code.toByte() }
            if (equals != null) {
                val key = String(b, p, equals - p, Charsets.US_ASCII).uppercase()
                if (key in keys && key !in tags) {
                    tags[key] = String(b, equals + 1, p + length - equals - 1, Charsets.UTF_8)
                }
            }
            p += length
        }
        return tags
    }

    private fun readId3(data: DataInputStream, major: Int, keys: Set<String>): Map<String, String> {
        if (major !in 3..4) return emptyMap() // ID3v2.2 uses 3-letter frame IDs
        data.readUnsignedByte() // revision
        val flags = data.readUnsignedByte()
        val size = syncsafe(data.readInt())
        if (size > MAX_TAG_BYTES) return emptyMap()
        val tag = ByteArray(size)
        data.readFully(tag)
        // shortcut: unsynchronised tags are rare in modern files; read them if lyrics go missing.
        if (flags and 0x80 != 0) return emptyMap()
        val tags = linkedMapOf<String, String>()
        var p = 0
        if (flags and 0x40 != 0) {
            val extended = int(tag, 0)
            p = if (major == 4) syncsafe(extended) else extended + 4
        }
        while (p + 10 <= tag.size) {
            if (tag[p] == 0.toByte()) break // padding
            val id = String(tag, p, 4, Charsets.ISO_8859_1)
            val raw = int(tag, p + 4)
            val length = if (major == 4) syncsafe(raw) else raw
            val body = p + 10
            if (length <= 0 || body + length > tag.size) break
            when (id) {
                "USLT" -> if ("USLT" in keys && "USLT" !in tags) {
                    tags["USLT"] = describedText(tag, body + 4, body + length, tag[body].toInt()).second
                }
                "TXXX" -> {
                    val (description, value) =
                        describedText(tag, body + 1, body + length, tag[body].toInt())
                    val key = description.uppercase()
                    if (key in keys && key !in tags) tags[key] = value
                }
            }
            p = body + length
        }
        return tags
    }

    /** Splits "description\0text" in the frame's text encoding. */
    private fun describedText(b: ByteArray, start: Int, end: Int, encoding: Int): Pair<String, String> {
        val charset: Charset = when (encoding) {
            0 -> Charsets.ISO_8859_1
            1 -> Charsets.UTF_16
            2 -> Charsets.UTF_16BE
            else -> Charsets.UTF_8
        }
        val wide = encoding == 1 || encoding == 2
        var p = start
        if (wide) {
            while (p + 1 < end && !(b[p] == 0.toByte() && b[p + 1] == 0.toByte())) p += 2
        } else {
            while (p < end && b[p] != 0.toByte()) p++
        }
        val description = String(b, start, p - start, charset)
        val textStart = minOf(end, p + if (wide) 2 else 1)
        // UTF-16 text carries its own BOM, so decode it separately from the description.
        val text = String(b, textStart, end - textStart, charset).trimEnd('\u0000')
        return description to text
    }

    private fun int(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0xFF) shl 24) or ((b[at + 1].toInt() and 0xFF) shl 16) or
            ((b[at + 2].toInt() and 0xFF) shl 8) or (b[at + 3].toInt() and 0xFF)

    private fun syncsafe(x: Int): Int =
        (x and 0x7F) or ((x shr 8 and 0x7F) shl 7) or ((x shr 16 and 0x7F) shl 14) or
            ((x shr 24 and 0x7F) shl 21)

    private fun ByteArray.startsWith(text: String, offset: Int = 0): Boolean =
        size >= offset + text.length &&
            text.indices.all { this[offset + it] == text[it].code.toByte() }

    private fun DataInputStream.skipFully(count: Int) = skipFully(count.toLong())

    private fun DataInputStream.skipFully(count: Long) {
        var left = count
        while (left > 0) {
            val skipped = skip(left)
            if (skipped <= 0) {
                readByte() // throws EOFException at end of stream
                left--
            } else {
                left -= skipped
            }
        }
    }
}
