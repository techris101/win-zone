package app.winzone.player

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.*
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

// Watches the game screen during a match, reads it on the phone, and sends what it reads to WIN ZONE.
// Nothing is recorded or uploaded as video: only the text values (screen type, score, clock).
class CaptureService : Service() {
    companion object {
        const val EXTRA_CODE = "code"; const val EXTRA_DATA = "data"
        const val ACTION_STOP = "app.winzone.player.STOP"
        const val DONE_ID = 8
        const val MAX_MINUTES = 150L          // safety: never record longer than this
        const val CHANNEL = "capture"; const val NOTE_ID = 7
        @Volatile var lastStatus: String = ""
        @Volatile var running = false
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var wake: PowerManager.WakeLock? = null
    private lateinit var store: Store
    private lateinit var parser: ScreenParser
    private var interval = 2000L
    private var confirmFrames = 2
    private var busy = false
    private var lastSent: Frame? = null
    private var lastSentAt = 0L
    private var lastStatusAt = 0L
    private var terminal: Frame? = null
    private var terminalCount = 0
    private var reported = false
    private var finished = false
    private var sawInPlay = false
    private var startedAt = 0L
    private var lastUnknownAt = 0L
    private var lastPlaySampleAt = 0L
    private var playSamples = 0
    private var lastFrameAt = 0L
    private var lastBlankReportAt = 0L
    private var busySince = 0L
    private var lastNoteAt = 0L
    private var capW = 0
    private var capH = 0
    private var frames = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {          // "Stop recording" button in the notification
            if (running) endCapture("Recording stopped.") else stopSelf()
            return START_NOT_STICKY
        }
        store = Store(this)
        val profile = store.profile ?: JSONObject()
        interval = profile.optLong("sample_interval_ms", 2000L).coerceIn(1000L, 5000L)
        confirmFrames = profile.optInt("confirm_frames", 2).coerceIn(1, 5)
        val m = store.match
        parser = ScreenParser(profile, store.myTeam ?: m?.optString("my_team")?.ifBlank { null }, m?.optString("opp_team")?.ifBlank { null })

        startInForeground("Watching your match")
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
            else @Suppress("DEPRECATION") intent?.getParcelableExtra(EXTRA_DATA)
        if (data == null || store.pass == null) { stopSelf(); return START_NOT_STICKY }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        projection = mpm.getMediaProjection(code, data)
        projection?.registerCallback(object : MediaProjection.Callback() { override fun onStop() { if (running) stopAll() } }, main)

        val dm = resources.displayMetrics
        val scale = minOf(1f, 1280f / maxOf(dm.widthPixels, dm.heightPixels))
        val w = (dm.widthPixels * scale).toInt(); val h = (dm.heightPixels * scale).toInt()
        capW = w; capH = h
        reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        display = projection?.createVirtualDisplay("winzone", w, h, dm.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader!!.surface, null, main)
        wake = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "winzone:capture").apply { acquire(3 * 60 * 60 * 1000L) }
        running = true
        startedAt = SystemClock.elapsedRealtime()
        lastFrameAt = startedAt
        main.postDelayed(tick, interval)
        return START_NOT_STICKY
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            if (SystemClock.elapsedRealtime() - startedAt > MAX_MINUTES * 60_000) { endCapture("Recording stopped after ${MAX_MINUTES / 60} hours."); return }
            val now = SystemClock.elapsedRealtime()
            followRotation()
            if (busy && now - busySince > 10_000) busy = false            // the reader never answered: try again
            if (!busy) grab()
            // no picture for 20 s (screen sharing stopped or blank): tell the server, so it is visible at once
            if (now - lastFrameAt > 20_000 && now - lastBlankReportAt > 30_000) {
                lastBlankReportAt = now
                val secs = (now - lastFrameAt) / 1000
                io.execute { send("submit_screen_state_pass", JSONObject().put("p_pass", store.pass).put("p_layout", "unknown")
                    .put("p_client_seq", store.nextSeq()).put("p_raw", JSONObject().put("app", Config.VERSION).put("no_picture_seconds", secs))) }
                note("No picture from the screen for $secs s. Is the game open?")
            }
            main.postDelayed(this, interval)
        }
    }

    // games turn the phone sideways: the capture follows, so the picture is not shrunk into a portrait frame
    private fun followRotation() {
        val dm = android.util.DisplayMetrics()
        @Suppress("DEPRECATION") (getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager).defaultDisplay.getRealMetrics(dm)
        val landscape = dm.widthPixels > dm.heightPixels
        if (capW == 0 || landscape == (capW > capH)) return
        val scale = minOf(1f, 1280f / maxOf(dm.widthPixels, dm.heightPixels))
        val w = (dm.widthPixels * scale).toInt(); val h = (dm.heightPixels * scale).toInt()
        try {
            val old = reader
            val next = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
            display?.resize(w, h, dm.densityDpi)
            display?.surface = next.surface
            reader = next; capW = w; capH = h
            try { old?.close() } catch (_: Exception) {}
        } catch (_: Exception) {}
    }

    private fun grab() {
        val img = reader?.acquireLatestImage() ?: return
        busy = true
        busySince = SystemClock.elapsedRealtime()
        lastFrameAt = busySince
        frames++
        val bmp: Bitmap
        try {
            val plane = img.planes[0]
            val rowPad = plane.rowStride - plane.pixelStride * img.width
            val full = Bitmap.createBitmap(img.width + rowPad / plane.pixelStride, img.height, Bitmap.Config.ARGB_8888)
            full.copyPixelsFromBuffer(plane.buffer)
            bmp = Bitmap.createBitmap(full, 0, 0, img.width, img.height)
            if (bmp !== full) full.recycle()
        } catch (e: Exception) { busy = false; return } finally { img.close() }
        val W = bmp.width.toFloat(); val H = bmp.height.toFloat()
        recognizer.process(InputImage.fromBitmap(bmp, 0))
            .addOnSuccessListener { text ->
                val lines = ArrayList<TextLine>()
                val words = ArrayList<TextLine>()
                for (b in text.textBlocks) for (l in b.lines) {
                    val r = l.boundingBox ?: continue
                    lines.add(TextLine(l.text, r.left / W, r.top / H, r.right / W, r.bottom / H))
                    for (e in l.elements) {
                        val q = e.boundingBox ?: continue
                        words.add(TextLine(e.text, q.left / W, q.top / H, q.right / W, q.bottom / H))
                    }
                }
                val frame = parser.parse(lines, words, deviceTimes())
                io.execute { handle(frame, lines) }
            }
            .addOnCompleteListener { bmp.recycle(); busy = false }
    }

    // runs on the io thread
    // "FULL TIME" ends the match only when nothing more will be played: always in a league or group match,
    // in a knockout only when the score is not level (a level knockout goes on to extra time, then penalties).
    private fun fullTimeIsFinal(f: Frame): Boolean {
        if (!f.fullTime || f.scoreMe == null || f.scoreOpp == null) return false
        val stage = store.match?.optString("stage") ?: ""
        return if (stage == "knockout" || stage == "playoff") f.scoreMe != f.scoreOpp else true
    }

    private fun handle(frame: Frame, lines: List<TextLine>) {
        if (finished) return
        val now = SystemClock.elapsedRealtime()
        // a final "FULL TIME" counts as the result screen
        val f = if (fullTimeIsFinal(frame)) frame.copy(layout = "result") else frame
        val isEnd = f.layout == "result" || f.layout == "opponent_quit"
        if (isEnd) {
            // a result screen must be seen the same way on several frames before it counts
            if (f.sameAs(terminal)) terminalCount++ else { terminal = f; terminalCount = 1 }
            if (terminalCount < confirmFrames) return
        }
        if (f.layout == "unknown") {
            note("Reading the game… (screen not recognised yet)")
            if (now - lastUnknownAt > 15000) {
                lastUnknownAt = now
                val sample = JSONArray(lines.take(40).map { l ->
                    JSONArray().put(l.text).put((l.x0 * 100).toInt()).put((l.y0 * 100).toInt()).put((l.x1 * 100).toInt()).put((l.y1 * 100).toInt()) })
                send("submit_screen_state_pass", JSONObject().put("p_pass", store.pass).put("p_layout", "unknown")
                    .put("p_client_seq", store.nextSeq()).put("p_raw", JSONObject().put("app", Config.VERSION).put("lines", sample)))
            }
            return
        }
        if (f.layout == "in_play") sawInPlay = true
        note(when (f.layout) {
            "in_play" -> "Match on" + (f.clock?.let { " · ${it / 60 + 1}'" } ?: "") + (if (f.scoreMe != null) " · ${f.scoreMe}–${f.scoreOpp}" else "")
            "menu" -> "Waiting for the match to start"
            else -> "Reading the game"
        })
        val dup = f.sameAs(lastSent) && now - lastSentAt < 15000
        if (!dup || (isEnd && terminalCount == confirmFrames)) {
            val raw = JSONObject().put("app", Config.VERSION)
            if (isEnd) raw.put("lines", JSONArray(lines.take(60).map { it.text }))
            else if (f.layout == "in_play" && (playSamples < 3 || now - lastPlaySampleAt > 20_000)) {
                playSamples++; lastPlaySampleAt = now
                raw.put("lines", JSONArray(lines.take(40).map { l ->
                    JSONArray().put(l.text).put((l.x0 * 100).toInt()).put((l.y0 * 100).toInt()).put((l.x1 * 100).toInt()).put((l.y1 * 100).toInt()) }))
            }
            val body = JSONObject().put("p_pass", store.pass).put("p_layout", f.layout)
                .put("p_score_me", f.scoreMe ?: JSONObject.NULL).put("p_score_opp", f.scoreOpp ?: JSONObject.NULL)
                .put("p_pen_me", f.penMe ?: JSONObject.NULL).put("p_pen_opp", f.penOpp ?: JSONObject.NULL)
                .put("p_clock_seconds", f.clock ?: JSONObject.NULL).put("p_client_seq", store.nextSeq()).put("p_raw", raw)
            send("submit_screen_state_pass", body)
            lastSent = f; lastSentAt = now
            if (f.myTeam != null && store.myTeam == null) store.myTeam = f.myTeam
        }
        if (isEnd && !reported) {
            f.report?.let { r ->
                if (send("submit_match_report_pass", JSONObject().put("p_pass", store.pass).put("p_report", r))) reported = true
            }
            send("finalize_fixture_pass", JSONObject().put("p_pass", store.pass))
            reported = true
            finished = true
            // the end screen is confirmed and sent: stop recording now, the server settles the result
            main.post { endCapture(if (f.layout == "opponent_quit") "Opponent left the match. Result sent, recording stopped." else "Full time. Result sent, recording stopped.") }
            return
        }
        if (now - lastStatusAt > 10000) { lastStatusAt = now; checkStatus() }
    }

    // sends now; if the network fails, keeps it in a queue and tries again with the next frame
    private fun send(rpc: String, body: JSONObject): Boolean {
        flushQueue()
        return try { Api.rpc(rpc, body); true } catch (e: Api.HttpError) { e.code in 400..499 }
        catch (e: Exception) { store.enqueue(rpc, body); false }
    }

    private fun flushQueue() = Api.flush(store)

    private fun checkStatus() {
        try {
            val s = Api.rpc("match_status_pass", JSONObject().put("p_pass", store.pass))
            val st = s.optString("status")
            lastStatus = st
            // Only a finished or cancelled match stops recording from here. "Under review" does not: a match can be
            // under review from an earlier attempt and then be replayed; this phone stops on its own end screen.
            if (st == "completed" || st == "cancelled") {
                finished = true
                val msg = when {
                    st == "cancelled" -> "Match cancelled by the organisers"
                    s.optBoolean("winner_is_me") -> "Result confirmed: you won ${s.opt("score_me")}–${s.opt("score_opp")}"
                    else -> "Result confirmed: ${s.opt("score_me")}–${s.opt("score_opp")}"
                }
                main.post { endCapture(msg) }
            }
        } catch (_: Exception) {}
    }

    // the phone's own clock (status bar) in the usual formats, so it is never taken for the match clock
    private fun deviceTimes(): Set<String> {
        val c = java.util.Calendar.getInstance()
        val out = HashSet<String>()
        for (d in -1..1) {
            val x = c.clone() as java.util.Calendar; x.add(java.util.Calendar.MINUTE, d)
            val h = x.get(java.util.Calendar.HOUR_OF_DAY); val m = x.get(java.util.Calendar.MINUTE); val h12 = if (h % 12 == 0) 12 else h % 12
            out += "%d:%02d".format(h, m); out += "%02d:%02d".format(h, m); out += "%d:%02d".format(h12, m); out += "%02d:%02d".format(h12, m)
        }
        return out
    }

    // what the app is reading right now, shown in its notification (at most every 5 s)
    private fun note(text: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastNoteAt < 5000) return
        lastNoteAt = now
        main.post { try { (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTE_ID, buildNote(text)) } catch (_: Exception) {} }
    }

    private fun startInForeground(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Match capture", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MatchActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = buildNote(text)
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(NOTE_ID, n)
    }

    private fun buildNote(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MatchActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, CaptureService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        @Suppress("DEPRECATION")
        return b.setContentTitle("WIN ZONE — recording your match").setContentText(text)
            .setSmallIcon(R.drawable.ic_notify).setOngoing(true).setOnlyAlertOnce(true).setContentIntent(open)
            .addAction(Notification.Action.Builder(R.drawable.ic_notify, "Stop recording", stop).build()).build()
    }

    // stops the screen recording, removes the "recording" notification and leaves a short one that can be swiped away
    private fun endCapture(message: String) {
        if (finished || reported) store.ended = true
        if (!running && projection == null) { stopSelf(); return }
        stopAll()
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val open = PendingIntent.getActivity(this, 2, Intent(this, MatchActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
            nm.notify(DONE_ID, b.setContentTitle("WIN ZONE").setContentText(message).setSmallIcon(R.drawable.ic_notify)
                .setAutoCancel(true).setContentIntent(open).build())
        } catch (_: Exception) {}
    }

    private fun stopAll() {
        running = false
        main.removeCallbacks(tick)
        try { display?.release() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        projection = null
        try { if (wake?.isHeld == true) wake?.release() } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() { running = false; main.removeCallbacks(tick); recognizer.close(); io.shutdown(); super.onDestroy() }
}
