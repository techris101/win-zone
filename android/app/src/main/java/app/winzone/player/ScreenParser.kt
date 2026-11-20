package app.winzone.player

import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import kotlin.math.abs

// One line of text read on the screen, with its position as fractions of the frame (0..1).
data class TextLine(val text: String, val x0: Float, val y0: Float, val x1: Float, val y1: Float) {
    val cx get() = (x0 + x1) / 2f
    val cy get() = (y0 + y1) / 2f
}

// What one frame shows, from this player's point of view ("me" / "opp").
data class Frame(
    val layout: String,                 // in_play | result | opponent_quit | menu | unknown
    val scoreMe: Int? = null, val scoreOpp: Int? = null,
    val penMe: Int? = null, val penOpp: Int? = null,
    val clock: Int? = null,
    val myTeam: String? = null, val oppTeam: String? = null,
    val report: JSONObject? = null,     // scorers etc. from the result screen
) {
    // two frames are "the same" for duplicate suppression and for confirming a result
    fun sameAs(o: Frame?) = o != null && o.layout == layout && o.scoreMe == scoreMe && o.scoreOpp == scoreOpp &&
        o.penMe == penMe && o.penOpp == penOpp && (clock == null || o.clock == null || abs(clock - o.clock) <= 1)
}

// Reads the game screen with rules that come from the server (game profile), so they can be tuned without a new app.
class ScreenParser(private val rules: JSONObject, private val myTeamName: String?, private val oppTeamName: String?) {

    private fun list(key: String) = rules.optJSONArray(key)?.let { a -> (0 until a.length()).map { a.getString(it).uppercase() } } ?: emptyList()
    private fun band(key: String, a: Float, b: Float) = rules.optJSONArray(key)?.let { it.getDouble(0).toFloat() to it.getDouble(1).toFloat() } ?: (a to b)

    private val resultKeys = list("result_keywords")
    private val quitKeys = list("quit_keywords")
    private val menuKeys = list("menu_keywords")
    private val oppLabels = list("opponent_labels").ifEmpty { listOf("OPPONENT") }
    private val potmLabel = rules.optString("potm_label", "PLAYER OF THE MATCH").uppercase()
    private val header = band("header_band", 0f, 0.30f)
    private val events = band("events_band", 0.20f, 0.46f)
    private val inplayTop = band("inplay_top_band", 0f, 0.22f)
    private val clockRe = Regex(rules.optString("clock_regex", "^(\\d{1,3})[:.](\\d{2})$"))
    private val penRe = Regex(rules.optString("pen_regex", "^\\((\\d{1,2})\\)$"))
    private val minHits = rules.optInt("result_min_hits", 3)
    private val digitsRe = Regex("^\\d{1,2}$")
    private val eventRe = Regex("^(.{2,40}?)\\s*\\(([0-9 ,'+pen]+)\\)$", RegexOption.IGNORE_CASE)
    private val ratingRe = Regex("^\\d{1,2}[.,]\\d$")

    fun parse(lines: List<TextLine>): Frame {
        val all = lines.joinToString(" ") { it.text.uppercase() }
        val hits = { keys: List<String> -> keys.count { all.contains(it) } }
        val quit = hits(quitKeys) > 0
        val result = hits(resultKeys) >= minHits
        val menu = hits(menuKeys) >= 2

        val clockLine = lines.filter { it.cy in header.first..header.second && it.cx in 0.30f..0.70f }
            .firstOrNull { clockRe.matches(it.text.trim()) }
        val clock = clockLine?.let { clockRe.find(it.text.trim())!!.groupValues.let { g -> g[1].toInt() * 60 + g[2].toInt() } }

        val layout = when {
            quit -> "opponent_quit"
            result -> "result"
            menu -> "menu"
            clockLine != null && clockLine.cy in inplayTop.first..inplayTop.second -> "in_play"
            else -> "unknown"
        }
        if (layout == "menu" || layout == "unknown") return Frame(layout)

        // the score banner: digits left and right of the clock, penalties in brackets, team names on top
        val midX = clockLine?.cx ?: 0.5f
        val head = lines.filter { it.cy in header.first..header.second }
        val leftScore = head.filter { digitsRe.matches(it.text.trim()) && it.cx < midX }.maxByOrNull { it.cx }?.text?.trim()?.toInt()
        val rightScore = head.filter { digitsRe.matches(it.text.trim()) && it.cx > midX }.minByOrNull { it.cx }?.text?.trim()?.toInt()
        val leftPen = head.filter { penRe.matches(it.text.trim()) && it.cx < midX }.maxByOrNull { it.cx }?.let { penRe.find(it.text.trim())!!.groupValues[1].toInt() }
        val rightPen = head.filter { penRe.matches(it.text.trim()) && it.cx > midX }.minByOrNull { it.cx }?.let { penRe.find(it.text.trim())!!.groupValues[1].toInt() }
        val names = head.filter { isName(it.text) }
        val leftTeam = names.filter { it.cx < midX - 0.08f }.minByOrNull { it.cy }?.text?.trim()
        val rightTeam = names.filter { it.cx > midX + 0.08f }.minByOrNull { it.cy }?.text?.trim()

        // which side is mine: my team name first, then the "Opponent" label under the other team
        val iAmLeft: Boolean? = when {
            myTeamName != null && leftTeam != null && same(myTeamName, leftTeam) -> true
            myTeamName != null && rightTeam != null && same(myTeamName, rightTeam) -> false
            oppTeamName != null && leftTeam != null && same(oppTeamName, leftTeam) -> false
            oppTeamName != null && rightTeam != null && same(oppTeamName, rightTeam) -> true
            head.any { l -> oppLabels.contains(l.text.trim().uppercase()) && l.cx > midX } -> true
            head.any { l -> oppLabels.contains(l.text.trim().uppercase()) && l.cx < midX } -> false
            else -> null
        }
        // without knowing my side, reporting a score could flip it: report the screen type only
        if (iAmLeft == null) return Frame(layout, clock = clock)

        val me = if (iAmLeft) leftScore else rightScore
        val opp = if (iAmLeft) rightScore else leftScore
        val pm = if (iAmLeft) leftPen else rightPen
        val po = if (iAmLeft) rightPen else leftPen
        val myT = if (iAmLeft) leftTeam else rightTeam
        val opT = if (iAmLeft) rightTeam else leftTeam
        val report = if (layout == "result" || layout == "opponent_quit") buildReport(lines, iAmLeft, myT, opT) else null
        return Frame(layout, me, opp, pm, po, clock, myT, opT, report)
    }

    private fun isName(s: String): Boolean {
        val t = s.trim()
        if (t.length < 2 || t.any { it.isDigit() } || t.contains("(") || t.contains("[")) return false
        val up = t.uppercase()
        if (oppLabels.contains(up) || resultKeys.any { up.contains(it) } || up.contains("MATCH")) return false
        return t.count { it.isLetter() } >= 2 && t == up      // team names are written in capitals
    }

    private fun buildReport(lines: List<TextLine>, iAmLeft: Boolean, myT: String?, opT: String?): JSONObject {
        val goals = JSONArray()
        for (l in lines.filter { it.cy in events.first..events.second }) {
            val m = eventRe.find(l.text.trim()) ?: continue
            val player = m.groupValues[1].trim()
            val leftSide = l.cx < 0.5f
            val team = if (leftSide == iAmLeft) "me" else "opp"
            for (part in m.groupValues[2].split(",")) {
                val minute = Regex("\\d{1,3}").find(part)?.value?.toInt() ?: continue
                goals.put(JSONObject().put("player", player).put("minute", minute).put("team", team)
                    .put("pen", part.lowercase().contains("pen")))
            }
        }
        val report = JSONObject().put("goals", goals)
        myT?.let { report.put("my_team", it) }
        opT?.let { report.put("opp_team", it) }
        // player of the match: the panel sits on the side of the player's team
        lines.firstOrNull { it.text.uppercase().contains(potmLabel) }?.let { label ->
            val panel = lines.filter { it.cy > label.cy && abs(it.cx - label.cx) < 0.18f }
            val name = panel.firstOrNull { isName(it.text) && !it.text.uppercase().contains("RATING") }?.text?.trim()
            val rating = panel.firstOrNull { ratingRe.matches(it.text.trim()) }?.text?.trim()?.replace(",", ".")
            if (name != null) {
                val team = if ((label.cx < 0.5f) == iAmLeft) "me" else "opp"
                report.put("potm", JSONObject().put("player", name).put("team", team).apply { rating?.let { put("rating", it) } })
            }
        }
        return report
    }

    companion object {
        fun norm(s: String) = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "")
            .uppercase().replace(Regex("[^A-Z0-9]"), "")

        // tolerant name match: equal, one contains the other, or at most 2 letters different
        fun same(a: String, b: String): Boolean {
            val x = norm(a); val y = norm(b)
            if (x.isEmpty() || y.isEmpty()) return false
            if (x == y || (x.length >= 4 && y.contains(x)) || (y.length >= 4 && x.contains(y))) return true
            return lev(x, y) <= 2
        }

        private fun lev(a: String, b: String): Int {
            val d = IntArray(b.length + 1) { it }
            for (i in 1..a.length) {
                var prev = d[0]; d[0] = i
                for (j in 1..b.length) {
                    val tmp = d[j]
                    d[j] = minOf(d[j] + 1, d[j - 1] + 1, prev + if (a[i - 1] == b[j - 1]) 0 else 1)
                    prev = tmp
                }
            }
            return d[b.length]
        }
    }
}
