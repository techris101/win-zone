package app.winzone.player

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

// Calls the server's functions. The app never logs in: it uses a match pass that works for one match only.
object Api {
    class HttpError(val code: Int, msg: String) : Exception(msg)

    fun rpc(name: String, body: JSONObject): JSONObject {
        val conn = URL("${Config.SUPABASE_URL}/rest/v1/rpc/$name").openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("apikey", Config.ANON_KEY)
            conn.setRequestProperty("Authorization", "Bearer ${Config.ANON_KEY}")
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader()?.readText() ?: ""
            if (code !in 200..299) throw HttpError(code, text.take(200))
            return if (text.trim().startsWith("{")) JSONObject(text) else JSONObject().put("value", text)
        } finally {
            conn.disconnect()
        }
    }
}
