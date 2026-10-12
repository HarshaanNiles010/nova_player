package com.novaplayer.nova_player

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.nio.charset.Charset

/**
 * Reads embedded lyrics without decoding audio: Vorbis comments (FLAC, Ogg Opus/Vorbis),
 * ID3v2.3/2.4 USLT or TXXX frames (MP3) and the iTunes ©lyr atom (M4A).
 * Returns the raw text, often LRC.
 */
object LyricsReader {
    private val lyricKeys = setOf("LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "USLT")

    // Tags can hold large cover art; give up rather than buffer an absurd amount.
    private const val MAX_TAG_BYTES = 32 * 1024 * 1024

    fun read(input: InputStream): String? = try {
        val data = DataInputStream(input.buffered())
        val magic = ByteArray(4)
        data.readFully(magic)
        when {
            magic.startsWith("fLaC") -> readFlac(data)
            magic.startsWith("OggS") -> readOgg(data)
            magic.startsWith("ID3") -> readId3(data, magic[3].toInt())
            else -> {
                val type = ByteArray(4)
                data.readFully(type)
                if (type.startsWith("ftyp")) readMp4(data, int(magic, 0).toLong()) else null
            }
        }
    } catch (_: EOFException) {
        null
    }

    private fun readFlac(data: DataInputStream): String? {
        while (true) {
            val header = data.readUnsignedByte()
            val length = (data.readUnsignedByte() shl 16) or
                (data.readUnsignedByte() shl 8) or data.readUnsignedByte()
            if (header and 0x7F == 4) {
                val block = ByteArray(length)
                data.readFully(block)
                return vorbisLyrics(block, 0)
            }
            data.skipFully(length)
            if (header and 0x80 != 0) return null
        }
    }

    /** The comment header is the second Ogg packet; it may span several pages. */
    private fun readOgg(data: DataInputStream): String? {
        var packetIndex = 0
        val packet = ByteArrayOutputStream()
        var magicRead = true
        while (true) {
            if (!magicRead) {
                val magic = ByteArray(4)
                data.readFully(magic)
                if (!magic.startsWith("OggS")) return null
            }
            magicRead = false
            data.skipFully(22) // version, type, granule, serial, sequence, CRC
            val lacing = IntArray(data.readUnsignedByte()) { data.readUnsignedByte() }
            for (size in lacing) {
                if (packetIndex == 1) {
                    val chunk = ByteArray(size)
                    data.readFully(chunk)
                    packet.write(chunk)
                    if (packet.size() > MAX_TAG_BYTES) return null
                } else {
                    data.skipFully(size)
                }
                if (size < 255) {
                    if (packetIndex == 1) {
                        val bytes = packet.toByteArray()
                        return when {
                            bytes.startsWith("OpusTags") -> vorbisLyrics(bytes, 8)
                            bytes.size > 7 && bytes[0] == 3.toByte() &&
                                bytes.startsWith("vorbis", 1) -> vorbisLyrics(bytes, 7)
                            else -> null
                        }
                    }
                    packetIndex++
                }
            }
        }
    }

    /** Walks top-level atoms (skipping the audio) until moov, then finds udta/meta/ilst/©lyr. */
    private fun readMp4(data: DataInputStream, ftypSize: Long): String? {
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
            if (size == 0L) return null // last atom runs to end of file and is not moov
            if (size < header) return null
            if (!type.startsWith("moov")) {
                data.skipFully(size - header)
                continue
            }
            if (size - header > MAX_TAG_BYTES) return null
            val moov = ByteArray((size - header).toInt())
            data.readFully(moov)
            val (start, end) = findAtom(moov, 0, moov.size, listOf("udta", "meta", "ilst", "\u00A9lyr", "data"))
                ?: return null
            // data atom body: 4-byte type, 4-byte locale, then UTF-8 text.
            if (end - start < 8) return null
            return String(moov, start + 8, end - start - 8, Charsets.UTF_8)
        }
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

    private fun vorbisLyrics(b: ByteArray, start: Int): String? {
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
            if (length < 0 || p + length > b.size) return null
            // Only decode the key; picture comments can be megabytes long.
            val equals = (p until p + minOf(length, 64)).firstOrNull { b[it] == '='.code.toByte() }
            if (equals != null &&
                String(b, p, equals - p, Charsets.US_ASCII).uppercase() in lyricKeys
            ) {
                return String(b, equals + 1, p + length - equals - 1, Charsets.UTF_8)
            }
            p += length
        }
        return null
    }

    private fun readId3(data: DataInputStream, major: Int): String? {
        if (major !in 3..4) return null // ID3v2.2 uses 3-letter frame IDs
        data.readUnsignedByte() // revision
        val flags = data.readUnsignedByte()
        val size = syncsafe(data.readInt())
        if (size > MAX_TAG_BYTES) return null
        val tag = ByteArray(size)
        data.readFully(tag)
        // shortcut: unsynchronised tags are rare in modern files; read them if lyrics go missing.
        if (flags and 0x80 != 0) return null
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
                "USLT" -> return describedText(tag, body + 4, body + length, tag[body].toInt()).second
                "TXXX" -> {
                    val (description, value) =
                        describedText(tag, body + 1, body + length, tag[body].toInt())
                    if (description.uppercase() in lyricKeys) return value
                }
            }
            p = body + length
        }
        return null
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
