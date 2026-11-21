package app.winzone.player

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.widget.*
import org.json.JSONObject
import kotlin.concurrent.thread

// The match screen: connects one match (one-time code from "Play game"), records it, then shows the result.
class MatchActivity : Activity() {
    private val BLACK = Color.parseColor("#0B0D0C"); private val BONE = Color.parseColor("#F2EFE8"); private val VOLT = Color.parseColor("#C8F43A")
    private val REQ_CAPTURE = 1; private val REQ_NOTIFY = 2
    private lateinit var store: Store
    private lateinit var root: LinearLayout
    private val ui = Handler(Looper.getMainLooper())
    private var roomCode: String? = null

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        store = Store(this)
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(48), dp(24), dp(24)); setBackgroundColor(BLACK) }
        setContentView(ScrollView(this).apply { setBackgroundColor(BLACK); addView(root) })
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        // results saved while offline are sent as soon as the app is open again
        if (store.pass != null) thread { try { Api.flush(store) } catch (_: Exception) {} }
        if (!CaptureService.running && store.match != null && ::root.isInitialized && intent?.data == null) render()
    }

    override fun onNewIntent(i: Intent) { super.onNewIntent(i); setIntent(i); handle(i) }

    private fun handle(i: Intent?) {
        val uri = i?.data
        if (uri != null && uri.scheme == "winzone") {
            // c = the one-time handoff code from the website (the room code stays on the website, with its copy button)
            val code = uri.getQueryParameter("c")
            roomCode = uri.getQueryParameter("room")
            if (code != null) { redeem(code); return }
        }
        render()
    }

    // turns the one-time code from the website into a match pass for this phone
    private fun redeem(code: String) {
        show("Connecting to your match…")
        thread {
            try {
                val r = Api.rpc("redeem_app_handoff", JSONObject().put("p_code", code))
                if (!r.optBoolean("ok", false)) throw Exception(r.optString("error", "This link has expired. Press Play game again on the website."))
                store.clearMatch()
                store.pass = r.getString("pass")
                store.match = r
                store.myTeam = r.optString("my_team").ifBlank { null }
                val g = Api.rpc("game_profile_pass", JSONObject().put("p_pass", store.pass))
                g.optJSONObject("profile")?.let { store.profile = it }
                ui.post { render() }
            } catch (e: Exception) {
                ui.post { show(friendly(e)); addButton("Back to WIN ZONE") { open("${Config.SITE}/me.html") } }
            }
        }
    }

    private fun render() {
        root.removeAllViews()
        title("WIN ZONE")
        val m = store.match
        if (store.pass == null || m == null) {
            text("No match connected.", BONE, 18f)
            text("Open your match on the WIN ZONE website and press Play game. This app opens by itself and connects.", 0xFF9A9A94.toInt(), 15f)
            addButton("Back to WIN ZONE") { open("${Config.SITE}/me.html") }
            return
        }
        // an old app version may misread the game: ask to update (the newest version is named by the server)
        store.profile?.optString("min_app")?.takeIf { it.isNotBlank() && older(Config.VERSION, it) }?.let { need ->
            text("Update needed: this is version ${Config.VERSION}, matches need $need or newer.", 0xFFFF5A4F.toInt(), 15f, bold = true)
            addButton("Download the new version", primary = true) { open(Config.APK_URL) }
        }
        label("YOUR MATCH")
        text("${m.optString("my_team").ifBlank { "You" }}  vs  ${m.optString("opponent")}", BONE, 22f, bold = true)
        text("${m.optString("stage")} · ${if (m.optInt("extra_time_seconds") > 0) "extra time and penalties if level" else "ends at full time"}", 0xFF9A9A94.toInt(), 14f)

        roomCode?.let { c ->
            label("PRIVATE MATCH CODE")
            text(c, VOLT, 34f, bold = true)
            addButton("Copy code") {
                (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("code", c))
                Toast.makeText(this, "Code copied", Toast.LENGTH_SHORT).show()
            }
            text("Both players type this same code in Private Match and press Search.", 0xFF9A9A94.toInt(), 14f)
        }

        if (store.myTeam == null) {
            label("YOUR TEAM NAME IN THE GAME")
            val input = EditText(this).apply { setTextColor(BONE); setHintTextColor(0xFF666666.toInt()); hint = "Exactly as shown in the game"; isSingleLine = true }
            root.addView(input)
            addButton("Save team name") {
                val name = input.text.toString().trim()
                if (name.length < 2) return@addButton
                thread {
                    val ok = try { Api.rpc("set_team_name_pass", JSONObject().put("p_pass", store.pass).put("p_name", name)); true } catch (e: Exception) { false }
                    ui.post { if (ok) { store.myTeam = name.uppercase(); render() } else Toast.makeText(this, "Could not save. Check your connection.", Toast.LENGTH_SHORT).show() }
                }
            }
        }

        if (store.ended) { renderEnded(); return }

        label("STATUS")
        val status = text(if (CaptureService.running) "Watching your match. Play normally; the result is sent by itself." else "Ready. Press Start, allow screen capture, then open the game.", BONE, 16f)
        if (!CaptureService.running) addButton("Start", primary = true) { start() }
        else {
            addButton("Back to the game") { launchGame() }
            addButton("Stop recording") {
                startService(Intent(this, CaptureService::class.java).setAction(CaptureService.ACTION_STOP))
                ui.postDelayed({ render() }, 500)
            }
        }
        text("The app reads only the score, clock and result screen on this phone. No video is saved or sent.", 0xFF9A9A94.toInt(), 13f)
        pollStatus(status)
    }

    // "Match ended": the result (or that it is waiting for the other phone) and the player's statistics
    private fun renderEnded() {
        label("MATCH ENDED")
        val head = text("Result sent. Waiting for the result to be confirmed…", BONE, 18f, bold = true)
        val sub = text("", 0xFF9A9A94.toInt(), 14f)
        val statsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(statsBox)
        addButton("Open the tournament") { open("${Config.SITE}/t/${store.match?.optString("slug") ?: ""}") }
        addButton("My matches") { open("${Config.SITE}/me.html") }
        fun load() {
            thread {
                val s = try { Api.rpc("match_status_pass", JSONObject().put("p_pass", store.pass)) } catch (_: Exception) { null }
                ui.post {
                    if (s == null) { sub.text = "No connection. The result is sent as soon as you are online."; return@post }
                    s.optString("slug").takeIf { it.isNotBlank() }?.let { slug -> store.match = store.match?.put("slug", slug) }
                    val me = s.opt("score_me"); val opp = s.opt("score_opp")
                    val pens = if (!s.isNull("pen_me") && !s.isNull("pen_opp")) " (pens ${s.opt("pen_me")}–${s.opt("pen_opp")})" else ""
                    when (s.optString("status")) {
                        "completed" -> {
                            head.text = when {
                                s.isNull("winner_is_me") -> "Draw $me–$opp"
                                s.optBoolean("winner_is_me") -> "You won $me–$opp$pens"
                                else -> "You lost $me–$opp$pens"
                            }
                            head.setTextColor(VOLT)
                            sub.text = "vs ${s.optString("opponent")} · ${s.optString("tournament")} · confirmed"
                        }
                        "disputed", "stalled" -> { head.text = "Result under review"; sub.text = "The organisers will check this match and confirm the result." }
                        else -> { sub.text = "vs ${s.optString("opponent")} · ${s.optString("tournament")}"; ui.postDelayed({ load() }, 8000) }
                    }
                    s.optJSONObject("stats")?.let { st -> showStats(statsBox, st) }
                }
            }
        }
        load()
    }

    private fun showStats(box: LinearLayout, st: JSONObject) {
        box.removeAllViews()
        val played = st.optInt("played"); val won = st.optInt("won")
        val rows = listOf("Played" to "$played", "Won" to "$won", "Win rate" to (if (played > 0) "${100 * won / played}%" else "—"),
            "Goals" to "${st.optInt("goals_for")}", "Titles" to "${st.optInt("titles")}")
        val head = TextView(this).apply { text = "YOUR STATISTICS"; setTextColor(0xFF9A9A94.toInt()); textSize = 12f; letterSpacing = 0.12f
            typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD); setPadding(0, dp(22), 0, dp(8)) }
        box.addView(head)
        val grid = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        for ((k, v) in rows) {
            val cell = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(4), dp(4), dp(4)) }
            cell.addView(TextView(this).apply { text = v; setTextColor(BONE); textSize = 24f; typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD) })
            cell.addView(TextView(this).apply { text = k.uppercase(); setTextColor(0xFF9A9A94.toInt()); textSize = 10f; letterSpacing = 0.1f })
            grid.addView(cell, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        box.addView(grid)
    }

    private fun pollStatus(view: TextView) {
        thread {
            try {
                val s = Api.rpc("match_status_pass", JSONObject().put("p_pass", store.pass))
                val st = s.optString("status")
                if (st == "completed" || (st == "disputed" && s.optBoolean("my_result_sent"))) { store.ended = true; ui.post { if (!CaptureService.running) render() }; return@thread }
                val msg = when (st) {
                    "completed" -> "Result confirmed: ${s.opt("score_me")}–${s.opt("score_opp")}" + if (s.optBoolean("winner_is_me")) " · you won" else ""
                    "disputed" -> "The two phones disagree. The organisers will check the result."
                    "live" -> if (CaptureService.running) "Match in progress. Keep playing." else "Match started. Press Start so the app can follow it."
                    else -> null
                }
                if (msg != null) ui.post { view.text = msg }
            } catch (_: Exception) {}
        }
    }

    private var askedNotify = false

    private fun start() {
        // ask for notifications once (they show what is being read); recording starts whatever the answer
        if (Build.VERSION.SDK_INT >= 33 && !askedNotify && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            askedNotify = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY); return
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        // Android 14+ offers "A single app" by default; that recording goes blank once the game is opened.
        // Asking for the default display makes Android offer only "Entire screen".
        val ask = if (Build.VERSION.SDK_INT >= 34) mpm.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay())
                  else mpm.createScreenCaptureIntent()
        Toast.makeText(this, "Choose \"Entire screen\" if Android asks.", Toast.LENGTH_LONG).show()
        startActivityForResult(ask, REQ_CAPTURE)
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, res: IntArray) {
        super.onRequestPermissionsResult(code, perms, res)
        if (code == REQ_NOTIFY) {
            if (res.isEmpty() || res[0] != PackageManager.PERMISSION_GRANTED)
                Toast.makeText(this, "Recording works without notifications, but you will not see what the app reads.", Toast.LENGTH_LONG).show()
            start()
        }
    }

    @Deprecated("Activity result API needs AndroidX; the framework call is fine here")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (req != REQ_CAPTURE) return
        if (res != RESULT_OK || data == null) { Toast.makeText(this, "Screen capture is needed to confirm the result.", Toast.LENGTH_LONG).show(); return }
        val svc = Intent(this, CaptureService::class.java).putExtra(CaptureService.EXTRA_CODE, res).putExtra(CaptureService.EXTRA_DATA, data)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc) else startService(svc)
        ui.postDelayed({ render(); launchGame() }, 600)
    }

    private fun launchGame() {
        val pkg = store.match?.optString("launch_package")?.ifBlank { null } ?: store.profile?.optString("package")?.ifBlank { null }
        val i = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
        if (i != null) startActivity(i) else Toast.makeText(this, "Now open the game and go to Private Match.", Toast.LENGTH_LONG).show()
    }

    private fun friendly(e: Exception) = when (e) {
        is Api.HttpError -> if (e.message?.contains("expired", true) == true || e.message?.contains("invalid", true) == true)
            "This link has expired. Press Play game again on the website." else "The server refused the request. Press Play game again on the website."
        else -> e.message?.takeIf { it.length < 120 && !it.contains("Exception") } ?: "No connection. Check your internet and try again."
    }

    private fun older(have: String, need: String): Boolean {
        val h = have.split(".").map { it.toIntOrNull() ?: 0 }; val n = need.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(h.size, n.size)) { val x = h.getOrElse(i) { 0 }; val y = n.getOrElse(i) { 0 }; if (x != y) return x < y }
        return false
    }

    // WIN ZONE pages open inside the app; anything else in the browser
    private fun open(url: String) {
        if (url.startsWith(Config.SITE)) {
            startActivity(Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_URL, url)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            finish()
        } else startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun show(msg: String) { root.removeAllViews(); title("WIN ZONE"); text(msg, BONE, 16f) }
    // the brand row: the same volt square logo as the website and the phone's home screen, then the name
    private fun title(s: String): TextView {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 0, 0, dp(22)) }
        row.addView(ImageView(this).apply { setImageResource(R.drawable.logo_square); contentDescription = null }, LinearLayout.LayoutParams(dp(40), dp(40)))
        val name = TextView(this).apply {
            text = s; setTextColor(BONE); textSize = 24f; letterSpacing = 0.06f
            typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD); setPadding(dp(12), 0, 0, 0)
        }
        row.addView(name)
        root.addView(row)
        return name
    }
    private fun label(s: String) = text(s, 0xFF9A9A94.toInt(), 12f, bold = true).also { it.setPadding(0, dp(22), 0, dp(4)); it.letterSpacing = 0.12f }

    private fun text(s: String, color: Int, size: Float, bold: Boolean = false): TextView =
        TextView(this).apply {
            text = s; setTextColor(color); textSize = size
            if (bold) typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD)
            setPadding(0, dp(4), 0, dp(4))
        }.also { root.addView(it) }

    private fun addButton(s: String, primary: Boolean = false, onClick: () -> Unit) {
        val b = Button(this).apply {
            text = s; isAllCaps = false; textSize = 16f
            setTextColor(if (primary) BLACK else BONE)
            background = GradientDrawable().apply { cornerRadius = dp(4).toFloat(); if (primary) setColor(VOLT) else { setColor(BLACK); setStroke(dp(1), BONE) } }
            setOnClickListener { onClick() }
        }
        root.addView(b, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(52)).apply { topMargin = dp(12) })
    }
}
