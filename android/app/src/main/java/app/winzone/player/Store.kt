package app.winzone.player

import android.content.Context
import org.json.JSONObject

// What the app remembers about the current match. The pass is private to this app and expires with the match.
class Store(ctx: Context) {
    private val p = ctx.getSharedPreferences("winzone", Context.MODE_PRIVATE)

    var pass: String? get() = p.getString("pass", null); set(v) = p.edit().putString("pass", v).apply()
    var match: JSONObject?
        get() = p.getString("match", null)?.let { JSONObject(it) }
        set(v) = p.edit().putString("match", v?.toString()).apply()
    var profile: JSONObject?
        get() = p.getString("profile", null)?.let { JSONObject(it) }
        set(v) = p.edit().putString("profile", v?.toString()).apply()
    var myTeam: String? get() = p.getString("my_team", null); set(v) = p.edit().putString("my_team", v).apply()
    var seq: Long get() = p.getLong("seq", 0); set(v) = p.edit().putLong("seq", v).apply()
    var queue: String get() = p.getString("queue", "[]")!!; set(v) = p.edit().putString("queue", v).apply()

    var ended: Boolean get() = p.getBoolean("ended", false); set(v) = p.edit().putBoolean("ended", v).apply()

    fun nextSeq(): Long { val s = seq + 1; seq = s; return s }

    @Synchronized fun enqueue(rpc: String, body: JSONObject) {
        val q = org.json.JSONArray(queue)
        if (q.length() < 200) q.put(JSONObject().put("rpc", rpc).put("body", body))
        queue = q.toString()
    }

    @Synchronized fun takeQueue(): org.json.JSONArray { val q = org.json.JSONArray(queue); queue = "[]"; return q }

    fun clearMatch() {
        p.edit().remove("pass").remove("match").remove("queue").remove("ended").putLong("seq", 0).apply()
    }
}
