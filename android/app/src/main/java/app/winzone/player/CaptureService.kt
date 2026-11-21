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
    private var menuStreak = 0
    private var startedAt = 0L

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
        val mpm = getSystemService(MediaProjectionManager::class.java)
        projection = mpm.getMediaProjection(code, data)
        projection?.registerCallback(object : MediaProjection.Callback() { override fun onStop() { if (running) stopAll() } }, main)

        val dm = resources.displayMetrics
        val scale = minOf(1f, 1280f / maxOf(dm.widthPixels, dm.heightPixels))
        val w = (dm.widthPixels * scale).toInt(); val h = (dm.heightPixels * scale).toInt()
        reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        display = projection?.createVirtualDisplay("winzone", w, h, dm.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader!!.surface, null, main)
        wake = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "winzone:capture").apply { acquire(3 * 60 * 60 * 1000L) }
        running = true
        startedAt = SystemClock.elapsedRealtime()
        main.postDelayed(tick, interval)
        return START_NOT_STICKY
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            if (SystemClock.elapsedRealtime() - startedAt > MAX_MINUTES * 60_000) { endCapture("Recording stopped after ${MAX_MINUTES / 60} hours."); return }
            if (!busy) grab()
            main.postDelayed(this, interval)
        }
    }

    private fun grab() {
        val img = reader?.acquireLatestImage() ?: return
        busy = true
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
                val frame = parser.parse(lines, words)
                io.execute { handle(frame, lines) }
            }
            .addOnCompleteListener { bmp.recycle(); busy = false }
    }

    // runs on the io thread
    private fun handle(f: Frame, lines: List<TextLine>) {
        if (finished) return
        val now = SystemClock.elapsedRealtime()
        val isEnd = f.layout == "result" || f.layout == "opponent_quit"
        if (isEnd) {
            // a result screen must be seen the same way on several frames before it counts
            if (f.sameAs(terminal)) terminalCount++ else { terminal = f; terminalCount = 1 }
            if (terminalCount < confirmFrames) return
        }
        if (f.layout == "unknown") return
        if (f.layout == "in_play") { sawInPlay = true; menuStreak = 0 }
        // back in the game's menus after playing: the match is over even if the result screen was missed
        if (f.layout == "menu" && sawInPlay) {
            menuStreak++
            if (menuStreak >= 3) { flushQueue(); main.post { endCapture("Match ended. Recording stopped.") }; return }
        }
        val dup = f.sameAs(lastSent) && now - lastSentAt < 15000
        if (!dup || (isEnd && terminalCount == confirmFrames)) {
            val raw = JSONObject().put("app", Config.VERSION)
            if (isEnd) raw.put("lines", JSONArray(lines.take(60).map { it.text }))
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
            main.post { endCapture("Match ended. Result sent, recording stopped.") }
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
            if (st == "completed" || st == "disputed" || st == "void") {
                finished = true
                val msg = when {
                    st == "disputed" -> "Result under review by the organisers"
                    s.optBoolean("winner_is_me") -> "Result confirmed: you won ${s.opt("score_me")}–${s.opt("score_opp")}"
                    else -> "Result confirmed: ${s.opt("score_me")}–${s.opt("score_opp")}"
                }
                main.post { endCapture(msg) }
            }
        } catch (_: Exception) {}
    }

    private fun startInForeground(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Match capture", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val stop = PendingIntent.getService(this, 1, Intent(this, CaptureService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val n = b.setContentTitle("WIN ZONE — recording your match").setContentText(text)
            .setSmallIcon(R.drawable.ic_notify).setOngoing(true).setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop recording", stop).build()).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(NOTE_ID, n)
    }

    // stops the screen recording, removes the "recording" notification and leaves a short one that can be swiped away
    private fun endCapture(message: String) {
        if (!running && projection == null) { stopSelf(); return }
        stopAll()
        try {
            val nm = getSystemService(NotificationManager::class.java)
            val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
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
