package app.winzone.player

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// Text positions copied from a real result screen (1080 x 486): "NANGANI UNITED 0 34:49 3 SUPERBOYS UNITED".
class ScreenParserTest {
    private val rules = JSONObject()
        .put("result_keywords", JSONArray(listOf("HIGHLIGHTS", "CONTINUE", "MATCH RATING", "PLAYER OF THE MATCH", "POSSESSION", "SHOTS")))
        .put("menu_keywords", JSONArray(listOf("MATCH CODE", "SEARCH", "FRIEND MATCH", "SETTINGS")))
        .put("quit_keywords", JSONArray(listOf("OPPONENT QUIT", "FORFEITS THE MATCH")))
        .put("opponent_labels", JSONArray(listOf("OPPONENT")))

    private fun t(s: String, x0: Int, y0: Int, x1: Int, y1: Int, w: Float = 1080f, h: Float = 486f) = TextLine(s, x0 / w, y0 / h, x1 / w, y1 / h)

    private val resultLines = listOf(
        t("NANGANI UNITED", 178, 42, 372, 68), t("0 34:49 3", 458, 45, 620, 85), t("SUPERBOYS UNITED", 680, 42, 902, 68),
        t("PRIVATE MATCH", 494, 102, 586, 116), t("POSSESSION", 508, 195, 572, 207), t("SHOTS", 524, 225, 556, 236),
        t("MATCH RATING", 193, 294, 267, 305), t("PLAYER OF THE MATCH", 793, 294, 907, 305), t("HIGHLIGHTS", 107, 453, 188, 467), t("CONTINUE", 932, 453, 1000, 467))
    private val resultWords = listOf(t("0", 458, 47, 490, 83), t("34:49", 520, 55, 560, 73), t("3", 594, 47, 620, 83))

    @Test fun resultScreenGivesBothScoresFromMySide() {
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(resultLines, resultWords)
        assertEquals("result", f.layout)
        assertEquals(0, f.scoreMe); assertEquals(3, f.scoreOpp); assertEquals(34 * 60 + 49, f.clock)
    }

    @Test fun otherPhoneSeesTheMirror() {
        val f = ScreenParser(rules, "SUPERBOYS UNITED", null).parse(resultLines, resultWords)
        assertEquals(3, f.scoreMe); assertEquals(0, f.scoreOpp)
    }

    @Test fun letterOReadAsZero() {
        val words = listOf(t("O", 458, 47, 490, 83), t("34:49", 520, 55, 560, 73), t("3", 594, 47, 620, 83))
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(resultLines, words)
        assertEquals(0, f.scoreMe); assertEquals(3, f.scoreOpp)
    }

    @Test fun joinedLineWithoutWordsStillFindsTheClock() {
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(resultLines)
        assertEquals(34 * 60 + 49, f.clock)
    }

    @Test fun clockInTheCornerDuringPlayIsInPlay() {
        val lines = listOf(t("NAN 1 - 0 SUP", 30, 20, 190, 44), t("23:12", 200, 22, 250, 42))
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(lines, listOf(t("23:12", 200, 22, 250, 42)))
        assertEquals("in_play", f.layout); assertEquals(23 * 60 + 12, f.clock)
    }

    @Test fun unknownSideSendsNoScore() {
        val f = ScreenParser(rules, null, null).parse(resultLines.filter { it.text != "NANGANI UNITED" && it.text != "SUPERBOYS UNITED" }, resultWords)
        assertEquals("result", f.layout); assertNull(f.scoreMe)
    }

    // a match screen during play: short names and the clock in the top bar
    private val playLines = listOf(t("NAN", 380, 18, 420, 40), t("SUP", 640, 18, 680, 40), t("PRIVATE MATCH", 494, 60, 586, 74))
    private fun playWords(a: String, clock: String, b: String) = listOf(t("NAN", 380, 18, 420, 40), t(a, 440, 18, 460, 40),
        t(clock, 515, 20, 565, 38), t(b, 600, 18, 620, 40), t("SUP", 640, 18, 680, 40))

    @Test fun kickoffFrameIsZeroZeroAtOneSecond() {
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(playLines, playWords("0", "00:01", "0"))
        assertEquals("in_play", f.layout); assertEquals(1, f.clock); assertEquals(0, f.scoreMe); assertEquals(0, f.scoreOpp)
    }

    @Test fun shortNamesGiveMySide() {
        val f = ScreenParser(rules, "SUPERBOYS UNITED", null).parse(playLines, playWords("2", "63:10", "1"))
        assertEquals(1, f.scoreMe); assertEquals(2, f.scoreOpp)
    }

    @Test fun zeroZeroIsSentEvenWithoutKnowingMySide() {
        val f = ScreenParser(rules, null, null).parse(playLines, playWords("0", "00:02", "0"))
        assertEquals(0, f.scoreMe); assertEquals(0, f.scoreOpp)
    }

    @Test fun fullTimeUnderTheClockIsSeen() {
        val lines = playLines + t("FULL TIME", 505, 42, 575, 56)
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(lines, playWords("2", "90:00", "1"))
        assertEquals("in_play", f.layout); assertEquals(true, f.fullTime); assertEquals(2, f.scoreMe)
    }

    @Test fun phoneClockIsNotTheMatchClock() {
        // the phone's own clock (17:15) in the status bar while the game menu is open
        val lines = listOf(t("17:15", 30, 2, 80, 14), t("PRIVATE MATCH", 494, 60, 586, 74))
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(lines, listOf(t("17:15", 30, 2, 80, 14)), setOf("17:15"))
        assertEquals("unknown", f.layout)
    }

    @Test fun joinedScoreDuringPlay() {
        // top-left bar: "NAN 1-0 SUP" with the clock beside it
        val lines = listOf(t("NAN 1-0 SUP", 20, 10, 200, 34), t("23:12", 210, 12, 260, 32))
        val words = listOf(t("NAN", 20, 10, 60, 34), t("1-0", 90, 10, 130, 34), t("SUP", 160, 10, 200, 34), t("23:12", 210, 12, 260, 32))
        val f = ScreenParser(rules, "NANGANI UNITED", null).parse(lines, words)
        assertEquals("in_play", f.layout); assertEquals(1, f.scoreMe); assertEquals(0, f.scoreOpp)
        val k = ScreenParser(rules, null, null).parse(lines, listOf(t("NAN", 20, 10, 60, 34), t("0-0", 90, 10, 130, 34), t("SUP", 160, 10, 200, 34), t("00:01", 210, 12, 260, 32)))
        assertEquals(0, k.scoreMe); assertEquals(0, k.scoreOpp); assertEquals(1, k.clock)
    }
}
