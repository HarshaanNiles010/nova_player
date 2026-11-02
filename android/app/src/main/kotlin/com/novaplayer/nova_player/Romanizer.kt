package com.novaplayer.nova_player

import android.icu.text.Transliterator
import android.os.Build
import androidx.annotation.RequiresApi

/** Latin letters for lyrics in other scripts, using the rules built into Android 10 and later. */
object Romanizer {
    private val kana = Regex("[぀-ヿ]")
    private val han = Regex("[一-鿿]")

    @RequiresApi(Build.VERSION_CODES.Q)
    fun romanize(lines: List<String>): List<String> {
        val any = Transliterator.getInstance("Any-Latin")
        val plain = Transliterator.getInstance("Latin-ASCII")
        // Android's only reading of kanji is Chinese, so Japanese lyrics keep theirs.
        val japanese = Transliterator.getInstance("Hiragana-Latin; Katakana-Latin; Latin-ASCII")
        val isJapanese = lines.any { kana.containsMatchIn(it) }
        return lines.map { line ->
            when {
                isJapanese -> japanese.transliterate(line)
                // Pinyin needs its tone marks; elsewhere they only get in the way of reading.
                han.containsMatchIn(line) -> any.transliterate(line)
                else -> plain.transliterate(any.transliterate(line))
            }
        }
    }
}
