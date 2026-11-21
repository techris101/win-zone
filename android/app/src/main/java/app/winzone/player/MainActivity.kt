package app.winzone.player

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.CalendarContract
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast

// The app's home: the whole WIN ZONE site inside the app (tournaments, live scores, my matches, rankings, admin).
// Pages come from the website, so every website change is in the app at once. The match recorder stays native:
// "Play game" calls the bridge below and opens the match screen directly.
class MainActivity : Activity() {
    companion object {
        const val EXTRA_URL = "url"
        private const val REQ_FILE = 11
    }

    private lateinit var web: WebView
    private var fileCallback: ValueCallback<Array<Uri>>? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        if (Build.VERSION.SDK_INT >= 21) window.statusBarColor = Color.parseColor("#0B0D0C")
        web = WebView(this)
        web.setBackgroundColor(Color.parseColor("#0B0D0C"))
        with(web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true               // keeps the player signed in
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
            userAgentString = "$userAgentString WinZoneApp/${Config.VERSION}"   // the site knows it runs in the app
        }
        web.addJavascriptInterface(Bridge(), "WinZoneApp")
        web.webViewClient = object : WebViewClient() {
            // WIN ZONE pages stay inside; other sites (streams, sponsors, email) open in the browser
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = route(request.url)
            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = route(Uri.parse(url))
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) showOffline()
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            // screenshots for a dispute, sponsor logos: the phone's file picker
            override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                fileCallback?.onReceiveValue(null)
                fileCallback = callback
                return try { startActivityForResult(params.createIntent(), REQ_FILE); true }
                catch (e: Exception) { fileCallback = null; false }
            }
        }
        val frame = FrameLayout(this)
        frame.addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setContentView(frame)
        if (b != null) web.restoreState(b) else web.loadUrl(startUrl(intent))
    }

    private fun startUrl(i: Intent?): String {
        val u = i?.getStringExtra(EXTRA_URL)
        return if (u != null && u.startsWith(Config.SITE)) u else "${Config.SITE}/"
    }

    override fun onNewIntent(i: Intent) {
        super.onNewIntent(i)
        i.getStringExtra(EXTRA_URL)?.let { if (it.startsWith(Config.SITE)) web.loadUrl(it) }
    }

    private fun route(u: Uri): Boolean {
        val s = u.toString()
        if (s.startsWith(Config.SITE)) return false
        if (u.scheme == "winzone" || s.startsWith("intent://")) {     // an old-style Play game link
            val code = Uri.parse(s.replace("intent://", "winzone://").substringBefore("#Intent")).getQueryParameter("c")
            if (code != null) openMatch(code)
            return true
        }
        try { startActivity(Intent(Intent.ACTION_VIEW, u)) } catch (_: Exception) {}
        return true
    }

    private fun openMatch(code: String) {
        startActivity(Intent(this, MatchActivity::class.java).setData(Uri.parse("winzone://play?c=" + Uri.encode(code))))
    }

    private fun showOffline() {
        web.loadDataWithBaseURL(null, """
            <html><body style="margin:0;background:#0B0D0C;color:#F2EFE8;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;text-align:center">
            <div style="padding:24px"><div style="font-weight:800;font-size:26px;letter-spacing:.04em">NO CONNECTION</div>
            <p style="color:#9aa39d">Check your internet, then try again.</p>
            <button onclick="location.href='${Config.SITE}/'" style="background:#C8F43A;color:#0B0D0C;border:0;padding:14px 26px;font-weight:800;letter-spacing:.1em">TRY AGAIN</button></div></body></html>
        """.trimIndent(), "text/html", "utf-8", null)
    }

    // What the website can ask the app to do
    inner class Bridge {
        @JavascriptInterface fun version(): String = Config.VERSION
        // "Play game": the one-time code from the website opens the match screen (no browser, no second sign-in)
        @JavascriptInterface fun play(code: String) { runOnUiThread { openMatch(code) } }
        // "Add to calendar": the phone's calendar with the match filled in
        @JavascriptInterface fun addToCalendar(title: String, startMillis: Long, endMillis: Long, details: String) {
            runOnUiThread {
                try {
                    startActivity(Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI)
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, startMillis)
                        .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, endMillis)
                        .putExtra(CalendarContract.Events.TITLE, title)
                        .putExtra(CalendarContract.Events.DESCRIPTION, details))
                } catch (_: Exception) { Toast.makeText(this@MainActivity, "No calendar app found.", Toast.LENGTH_SHORT).show() }
            }
        }
    }

    @Deprecated("framework call, no AndroidX")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (req == REQ_FILE) {
            fileCallback?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(res, data))
            fileCallback = null
        }
    }

    @Deprecated("framework call")
    override fun onBackPressed() { if (web.canGoBack()) web.goBack() else super.onBackPressed() }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); web.saveState(out) }
    override fun onResume() { super.onResume(); web.onResume() }
    override fun onPause() { web.onPause(); super.onPause() }
    override fun onDestroy() { (web.parent as? ViewGroup)?.removeView(web); web.destroy(); super.onDestroy() }
}
