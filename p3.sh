mkdir -p $(dirname app/src/main/java/com/me/jarvis/JarvisService.kt)
cat > app/src/main/java/com/me/jarvis/JarvisService.kt <<'EOF'
package com.me.jarvis

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*
import android.speech.*
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.util.Locale
import android.content.ContentUris
import android.media.MediaPlayer
import android.net.Uri
import android.provider.MediaStore
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.SpeechService

object JarvisState {
    val status = MutableStateFlow("OFFLINE")
    val reply = MutableStateFlow("Tap ACTIVATE, then say \"Jarvis\".")
}

class JarvisService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var vosk: SpeechService? = null
    private var busy = false
    private var player: MediaPlayer? = null

    // Offline wake-word listener (no account or key needed)
    // Reacts only to a finished phrase that STARTS with "jarvis" (so video/TV audio is ignored)
    private val voskListener = object : org.vosk.android.RecognitionListener {
        override fun onPartialResult(h: String?) {}
        override fun onResult(h: String?) {
            val t = try { org.json.JSONObject(h ?: "").optString("text") } catch (e: Exception) { "" }
            val m = Regex("^(?:(?:hey|ok|okay|hi) )?jarvis(?: (.+))?$").find(t) ?: return
            onWake(m.groupValues[1])
        }
        override fun onFinalResult(h: String?) {}
        override fun onError(e: Exception?) {}
        override fun onTimeout() {}
    }

    private fun copyAssets(src: String, dest: File) {
        val kids = assets.list(src) ?: return
        if (kids.isEmpty()) {
            dest.parentFile?.mkdirs()
            assets.open(src).use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
        } else {
            dest.mkdirs()
            kids.forEach { copyAssets("$src/$it", File(dest, it)) }
        }
    }
    private var llm: LlmInference? = null
    private lateinit var tts: TextToSpeech
    private lateinit var stt: SpeechRecognizer

    override fun onBind(i: Intent?): IBinder? = null
    override fun onStartCommand(i: Intent?, f: Int, id: Int) = START_STICKY

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel("j", "Jarvis", NotificationManager.IMPORTANCE_LOW))
        val n = Notification.Builder(this, "j").setContentTitle("Jarvis is listening")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now).build()
        startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)

        tts = TextToSpeech(this) { tts.language = Locale.US }
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) { main.post { standby() } }
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) { main.post { standby() } }
        })

        stt = SpeechRecognizer.createSpeechRecognizer(this)
        stt.setRecognitionListener(object : RecognitionListener {
            override fun onResults(b: Bundle?) {
                val q = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                if (q == null) standby() else think(q)
            }
            override fun onError(e: Int) { standby() }
            override fun onReadyForSpeech(p: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(v: Float) {}
            override fun onBufferReceived(b: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(b: Bundle?) {}
            override fun onEvent(t: Int, b: Bundle?) {}
        })

        Thread {
            val f = File(filesDir, "model.task")
            try {
                if (f.exists()) llm = LlmInference.createFromOptions(
                    this, LlmInference.LlmInferenceOptions.builder()
                        .setModelPath(f.path).setMaxTokens(1024).build()
                )
            } catch (e: Exception) { JarvisState.reply.value = "Model error: " + e.message }
        }.start()

        JarvisState.status.value = "LOADING"
        JarvisState.reply.value = "Preparing wake word. First start takes a minute..."
        Thread {
            try {
                val dir = File(filesDir, "vosk")
                val ok = File(dir, "ok")
                if (!ok.exists()) {
                    copyAssets("model-en-us", File(dir, "model-en-us"))
                    ok.writeText("1")
                }
                val rec = Recognizer(Model(File(dir, "model-en-us").path), 16000f)
                val ss = SpeechService(rec, 16000f)
                main.post {
                    vosk = ss
                    JarvisState.reply.value = "Say \"Jarvis\"."
                    standby()
                }
            } catch (e: Exception) {
                JarvisState.reply.value = "Wake word error: " + e.message
            }
        }.start()
    }

    private fun onWake(rest: String) {
        if (busy) return
        busy = true
        main.post {
            vosk?.stop()
            if (rest.isNotBlank()) { think(rest); return@post }
            JarvisState.status.value = "LISTENING"
            main.postDelayed({
                stt.startListening(
                    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                )
            }, 300)
        }
    }

    private fun think(q: String) {
        JarvisState.status.value = "THINKING"
        val cmd = try { command(q) } catch (e: Exception) { "Sorry, that failed: " + e.message }
        if (cmd != null) { say(cmd); return }
        var ask = q
        if (Regex("screen").containsMatchIn(q.lowercase()) && Regex("read|summari|describe|what").containsMatchIn(q.lowercase())) {
            val t = JarvisAccess.inst?.screenText() ?: return say("Please switch on Jarvis under Accessibility first, sir.")
            ask = "This is the text on my phone screen: " + t.take(1200) + " My request: " + q
        }
        Thread {
            val a = try {
                llm?.generateResponse(
                    "<start_of_turn>user\nYou are JARVIS, a witty, concise AI butler. " +
                        "Answer in at most three sentences. " + ask +
                        "<end_of_turn>\n<start_of_turn>model\n"
                ) ?: "The language model is not installed yet, sir."
            } catch (e: Exception) { "Something went wrong: " + e.message }
            main.post { say(a) }
        }.start()
    }

    private fun say(a: String) {
        JarvisState.reply.value = a
        JarvisState.status.value = "SPEAKING"
        tts.speak(a, TextToSpeech.QUEUE_FLUSH, null, "u")
    }

    // Routes voice commands: music controls, play, file search, open app
    private fun command(q: String): String? {
        val l = q.trim().lowercase()
        if (Regex("^(pause|stop|resume|continue)( the)?( music| playing| song)?$").matches(l)) {
            val p = player ?: return "Nothing is playing, sir."
            if (l.startsWith("resume") || l.startsWith("continue")) p.start()
            else if (l.startsWith("pause")) p.pause()
            else { p.release(); player = null }
            return "Done, sir."
        }
        searchInApp(q)?.let { return it }
        Regex("^play\\s+(.+)$").find(l)?.let { return playSong(it.groupValues[1]) }
        findFiles(l)?.let { return it }
        screenCmd(q)?.let { return it }
        return openApp(q)
    }

    private fun search(uri: Uri, term: String, limit: Int): List<Pair<String, Uri>> {
        val like = "%" + term.trim().split(Regex("\\s+")).joinToString("%") + "%"
        val out = ArrayList<Pair<String, Uri>>()
        contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME),
            MediaStore.MediaColumns.DISPLAY_NAME + " LIKE ?", arrayOf(like), null
        )?.use { c ->
            while (c.moveToNext() && out.size < limit)
                out.add(Pair(c.getString(1), ContentUris.withAppendedId(uri, c.getLong(0))))
        }
        return out
    }

    private fun playSong(raw: String): String {
        val term = raw.replace(Regex("^(the |a )?(song|music|track)( called| named)? ?"), "").trim()
        if (term.isEmpty()) return "Which song, sir?"
        val hit = search(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, term, 1).firstOrNull()
            ?: return "I couldn't find a song called " + term + ", sir."
        player?.release()
        player = MediaPlayer().apply {
            setDataSource(this@JarvisService, hit.second)
            prepare()
            start()
        }
        return "Playing " + hit.first.substringBeforeLast('.') + "."
    }

    private fun findFiles(l: String): String? {
        val m = Regex("^(find|search for|search|look for|do i have)\\s+(.+)$").find(l) ?: return null
        if (!Regex("\\b(files?|songs?|music|videos?|photos?|pictures?|documents?|pdf)\\b").containsMatchIn(l)) return null
        val term = m.groupValues[2]
            .replace(Regex("^(any |a |the |my )?(files?|songs?|music|videos?|photos?|pictures?|documents?|pdfs?)?( named| called)? ?"), "")
            .trim()
        if (term.isEmpty()) return "What should I look for, sir?"
        val r = search(MediaStore.Files.getContentUri("external"), term, 20)
        if (r.isEmpty()) return "I couldn't find anything named " + term + ", sir."
        val n = if (r.size >= 20) "20 or more" else r.size.toString()
        return "I found " + n + " matching files, sir. For example: " + r.take(3).joinToString(", ") { it.first } + "."
    }

    private fun findApp(name: String): android.content.pm.ResolveInfo? {
        val want = name.trim().lowercase().removeSuffix(" app").replace(" ", "")
        if (want.isEmpty()) return null
        val pm = packageManager
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
        fun label(r: android.content.pm.ResolveInfo) = r.loadLabel(pm).toString().lowercase().replace(" ", "")
        return apps.firstOrNull { label(it) == want } ?: apps.firstOrNull { label(it).contains(want) }
    }

    private fun launch(app: android.content.pm.ResolveInfo): Boolean {
        val i = packageManager.getLaunchIntentForPackage(app.activityInfo.packageName) ?: return false
        startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }

    // "open youtube", "launch camera"
    private fun openApp(q: String): String? {
        val m = Regex("^(open|launch|start)\\s+(.+)$").find(q.trim().lowercase()) ?: return null
        val app = findApp(m.groupValues[2]) ?: return "I couldn't find an app called " + m.groupValues[2] + ", sir."
        return if (launch(app)) "Opening " + app.loadLabel(packageManager) + ", sir." else "I couldn't open that, sir."
    }

    // "search cats in youtube" / "open youtube and search cats"
    private fun searchInApp(q: String): String? {
        val t = q.trim()
        val m1 = Regex("^search (?:for )?(.+) (?:on|in) (?:the )?(.+?)(?: app)?$", RegexOption.IGNORE_CASE).find(t)
        val m2 = Regex("^open (.+?) and search (?:for )?(.+)$", RegexOption.IGNORE_CASE).find(t)
        val query = if (m1 != null) m1.groupValues[1] else if (m2 != null) m2.groupValues[2] else return null
        val name = if (m1 != null) m1.groupValues[2] else m2!!.groupValues[1]
        val app = findApp(name) ?: return null
        val a = JarvisAccess.inst ?: return "Please switch on Jarvis under Accessibility first, sir."
        if (!launch(app)) return "I couldn't open " + name + ", sir."
        main.postDelayed({
            if (!a.hasEditable()) a.tap("search")
            main.postDelayed({
                a.type(query)
                main.postDelayed({ a.enter() }, 700)
            }, 1500)
        }, 3000)
        return "Searching for " + query + " in " + name + ", sir."
    }

    // tap / type / scroll / back / home by voice
    private fun screenCmd(q: String): String? {
        val t = q.trim()
        val l = t.lowercase()
        if (!Regex("^(go back|back|go home|home|recent apps|show recents|press enter|enter|submit|scroll (up|down)|swipe (up|down|left|right)|(tap|click|press)( on)? .+|type .+)$").matches(l)) return null
        val a = JarvisAccess.inst ?: return "Please switch on Jarvis under Accessibility first, sir."
        val ok = when {
            l == "go back" || l == "back" -> a.global(1)
            l == "go home" || l == "home" -> a.global(2)
            l.startsWith("recent") || l == "show recents" -> a.global(3)
            l == "press enter" || l == "enter" || l == "submit" -> a.enter()
            l.startsWith("scroll") || l.startsWith("swipe") -> a.swipe(l.substringAfterLast(' '))
            l.startsWith("type ") -> a.type(t.substring(5))
            else -> a.tap(l.replace(Regex("^(tap|click|press)( on)? "), ""))
        }
        return if (ok) "Done, sir." else "I couldn't do that, sir."
    }

    private fun standby() {
        JarvisState.status.value = "STANDBY"
        busy = false
        vosk?.startListening(voskListener)
    }

    override fun onDestroy() {
        player?.release(); vosk?.shutdown(); stt.destroy(); tts.shutdown(); llm?.close()
        JarvisState.status.value = "OFFLINE"
        super.onDestroy()
    }
}
EOF
touch .ok3
