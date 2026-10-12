package com.novaplayer.nova_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.ByteArrayInputStream

class LyricsReaderTest {
    private val expected = "[00:01.00]First line\n[00:02.50]Second line"

    private fun fixture(name: String) =
        javaClass.classLoader!!.getResourceAsStream(name)!!

    @Test
    fun readsFlacVorbisComment() = assertEquals(expected, LyricsReader.read(fixture("lyr.flac")))

    @Test
    fun readsOpusTags() = assertEquals(expected, LyricsReader.read(fixture("lyr.opus")))

    @Test
    fun readsMp3TxxxFrame() = assertEquals(expected, LyricsReader.read(fixture("lyr.mp3")))

    @Test
    fun readsM4aWithMoovAfterAudio() = assertEquals(expected, LyricsReader.read(fixture("lyr.m4a")))

    @Test
    fun readsM4aWithMoovFirst() =
        assertEquals(expected, LyricsReader.read(fixture("lyr_faststart.m4a")))

    @Test
    fun readsUtf16UsltFrame() {
        // USLT: encoding 1 (UTF-16 with BOM), language, empty description, text.
        val text = "Hëllo\nworld"
        val body = byteArrayOf(1) + "eng".toByteArray() +
            byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0, 0) + text.toByteArray(Charsets.UTF_16)
        val frame = "USLT".toByteArray() + int(body.size) + byteArrayOf(0, 0) + body
        val tag = "ID3".toByteArray() + byteArrayOf(3, 0, 0) + syncsafe(frame.size) + frame
        assertEquals(text, LyricsReader.read(ByteArrayInputStream(tag)))
    }

    @Test
    fun returnsNullForUnknownOrTruncatedData() {
        assertNull(LyricsReader.read(ByteArrayInputStream("RIFFxxxx".toByteArray())))
        assertNull(LyricsReader.read(ByteArrayInputStream("fLaC".toByteArray())))
    }

    private fun int(v: Int) = byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte())

    private fun syncsafe(v: Int) = byteArrayOf(
        (v shr 21 and 0x7F).toByte(), (v shr 14 and 0x7F).toByte(),
        (v shr 7 and 0x7F).toByte(), (v and 0x7F).toByte(),
    )
}
