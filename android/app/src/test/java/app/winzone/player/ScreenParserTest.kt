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

    // the real match screen (1080 x 462): "FCB 3 - 0 PLA" top left, clock "45:00" with "+1", "TAP TO SKIP (1 / 2)" at the bottom
    private fun hud(w: Float = 1080f, h: Float = 462f) = Pair(
        listOf(TextLine("FCB 3 - 0 PLA", 88 / w, 12 / h, 228 / w, 34 / h), TextLine("45:00", 286 / w, 12 / h, 334 / w, 34 / h),
               TextLine("+1", 344 / w, 12 / h, 364 / w, 34 / h), TextLine("ULTIMATE CLASH SOCCER", 460 / w, 110 / h, 712 / w, 126 / h),
               TextLine("TAP TO SKIP (1 / 2)", 462 / w, 425 / h, 618 / w, 442 / h)),
        listOf(TextLine("FCB", 88 / w, 12 / h, 118 / w, 34 / h), TextLine("3", 138 / w, 12 / h, 150 / w, 34 / h), TextLine("-", 156 / w, 12 / h, 162 / w, 34 / h),
               TextLine("0", 168 / w, 12 / h, 182 / w, 34 / h), TextLine("PLA", 196 / w, 12 / h, 228 / w, 34 / h),
               TextLine("45:00", 286 / w, 12 / h, 334 / w, 34 / h), TextLine("+1", 344 / w, 12 / h, 364 / w, 34 / h)))

    @Test fun realMatchScreenHomeSide() {
        val (lines, words) = hud()
        val f = ScreenParser(rules, "FC BARCELONA", null).parse(lines, words)
        assertEquals("in_play", f.layout); assertEquals(45 * 60, f.clock); assertEquals(3, f.scoreMe); assertEquals(0, f.scoreOpp)
    }

    @Test fun realMatchScreenAwaySide() {
        val (lines, words) = hud()
        val f = ScreenParser(rules, "PLAYMAKERS", null).parse(lines, words)
        assertEquals(0, f.scoreMe); assertEquals(3, f.scoreOpp)
    }

    @Test fun realMatchScreenOnlyTheLine() {
        // when the phone reader gives the score bar as one line only
        val (lines, _) = hud()
        val f = ScreenParser(rules, "FC BARCELONA", null).parse(lines, emptyList())
        assertEquals("in_play", f.layout); assertEquals(3, f.scoreMe); assertEquals(0, f.scoreOpp)
    }

    @Test fun realMatchScreenKickoff() {
        val w = 1080f; val h = 462f
        val lines = listOf(TextLine("FCB 0 - 0 PLA", 88 / w, 12 / h, 228 / w, 34 / h), TextLine("00:01", 286 / w, 12 / h, 334 / w, 34 / h))
        val f = ScreenParser(rules, null, null).parse(lines, emptyList())
        assertEquals(1, f.clock); assertEquals(0, f.scoreMe); assertEquals(0, f.scoreOpp)
    }

    private fun hudWith(label: String, score: String, clock: String): Pair<List<TextLine>, List<TextLine>> {
        val w = 1080f; val h = 462f
        return Pair(listOf(TextLine("FCB $score PLA", 88 / w, 12 / h, 228 / w, 34 / h), TextLine(clock, 286 / w, 12 / h, 334 / w, 34 / h),
                           TextLine(label, 100 / w, 40 / h, 210 / w, 56 / h)), emptyList())
    }

    @Test fun fullTimeBelowTheScoreBar() {
        val (l, w) = hudWith("FULL TIME", "2 - 1", "90:00")
        val f = ScreenParser(rules, "FC BARCELONA", null).parse(l, w)
        assertEquals(true, f.fullTime); assertEquals(2, f.scoreMe); assertEquals(1, f.scoreOpp)
    }

    @Test fun halfTimeAndExtraTimeDoNotEndTheMatch() {
        for ((label, clock) in listOf("HALF TIME" to "45:00", "EXTRA TIME" to "90:00", "EXTRA TIME HALF TIME" to "105:00")) {
            val (l, w) = hudWith(label, "1 - 1", clock)
            assertEquals(label, false, ScreenParser(rules, "FC BARCELONA", null).parse(l, w).fullTime)
        }
    }

    @Test fun fullTimeAfterExtraTimeIsSeen() {
        val (l, w) = hudWith("FULL TIME", "2 - 2", "120:00")
        val f = ScreenParser(rules, "FC BARCELONA", null).parse(l, w)
        assertEquals(true, f.fullTime); assertEquals(120 * 60, f.clock)
    }
}
