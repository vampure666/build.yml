mkdir -p $(dirname app/src/main/java/com/me/jarvis/JarvisAccess.kt)
cat > app/src/main/java/com/me/jarvis/JarvisAccess.kt <<'EOF'
package com.me.jarvis

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class JarvisAccess : AccessibilityService() {
    companion object { var inst: JarvisAccess? = null }

    override fun onServiceConnected() { inst = this }
    override fun onAccessibilityEvent(e: AccessibilityEvent?) {}
    override fun onInterrupt() {}
    override fun onUnbind(i: Intent?): Boolean { inst = null; return super.onUnbind(i) }

    private fun find(pred: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        fun walk(n: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
            if (n == null) return null
            if (pred(n)) return n
            for (i in 0 until n.childCount) walk(n.getChild(i))?.let { return it }
            return null
        }
        return walk(rootInActiveWindow)
    }

    fun hasEditable() = find { it.isEditable } != null

    fun screenText(): String {
        val sb = StringBuilder()
        fun walk(n: AccessibilityNodeInfo?) {
            if (n == null) return
            n.text?.let { sb.append(it).append(". ") }
            n.contentDescription?.let { sb.append(it).append(". ") }
            for (i in 0 until n.childCount) walk(n.getChild(i))
        }
        walk(rootInActiveWindow)
        return sb.toString()
    }

    fun tap(label: String): Boolean {
        val want = label.trim().lowercase()
        val n = find { (it.text ?: it.contentDescription)?.toString()?.lowercase()?.contains(want) == true } ?: return false
        var c: AccessibilityNodeInfo? = n
        while (c != null && !c.isClickable) c = c.parent
        return (c ?: n).performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    fun type(text: String): Boolean {
        val n = find { it.isEditable && it.isFocused } ?: find { it.isEditable } ?: return false
        n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val b = Bundle()
        b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        return n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b)
    }

    fun enter(): Boolean {
        val n = find { it.isEditable && it.isFocused } ?: find { it.isEditable } ?: return false
        return n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
    }

    fun global(n: Int) = performGlobalAction(n)

    fun swipe(dir: String): Boolean {
        val d = resources.displayMetrics
        val w = d.widthPixels.toFloat()
        val h = d.heightPixels.toFloat()
        val p = Path()
        when (dir) {
            "down" -> { p.moveTo(w / 2, h * 0.7f); p.lineTo(w / 2, h * 0.3f) }
            "up" -> { p.moveTo(w / 2, h * 0.3f); p.lineTo(w / 2, h * 0.7f) }
            "left" -> { p.moveTo(w * 0.8f, h / 2); p.lineTo(w * 0.2f, h / 2) }
            else -> { p.moveTo(w * 0.2f, h / 2); p.lineTo(w * 0.8f, h / 2) }
        }
        return dispatchGesture(
            GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, 300)).build(), null, null
        )
    }
}
EOF
mkdir -p $(dirname app/src/main/java/com/me/jarvis/MainActivity.kt)
cat > app/src/main/java/com/me/jarvis/MainActivity.kt <<'EOF'
package com.me.jarvis

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                val status by JarvisState.status.collectAsState()
                val reply by JarvisState.reply.collectAsState()

                val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
                    uri?.let {
                        JarvisState.reply.value = "Importing model..."
                        Thread {
                            contentResolver.openInputStream(it)?.use { i ->
                                File(filesDir, "model.task").outputStream().use { o -> i.copyTo(o) }
                            }
                            JarvisState.reply.value = "Model imported. Tap ACTIVATE."
                        }.start()
                    }
                }
                val perms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
                    if (it[Manifest.permission.RECORD_AUDIO] == true)
                        startForegroundService(Intent(this@MainActivity, JarvisService::class.java))
                }

                Column(
                    Modifier.fillMaxSize().background(Color(0xFF02060D)).padding(24.dp).systemBarsPadding(),
                    Arrangement.SpaceBetween, Alignment.CenterHorizontally
                ) {
                    Text("J.A.R.V.I.S.", color = Color(0xFF00E5FF), fontSize = 22.sp,
                        fontFamily = FontFamily.Monospace, letterSpacing = 8.sp)
                    Hud(status)
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(status, color = Color(0xFF00E5FF), fontSize = 16.sp,
                            fontFamily = FontFamily.Monospace, letterSpacing = 4.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(reply, color = Color(0xFFCFEFFF), fontSize = 15.sp, textAlign = TextAlign.Center,
                            modifier = Modifier.heightIn(min = 70.dp))
                Row {
                    val cy = Color(0xFF00E5FF)
                    val pad = PaddingValues(horizontal = 8.dp)
                    TextButton({
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + packageName)))
                    }, contentPadding = pad) { Text("Open apps", color = cy, fontSize = 12.sp) }
                    TextButton({
                        startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:" + packageName)))
                    }, contentPadding = pad) { Text("File access", color = cy, fontSize = 12.sp) }
                    TextButton({
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    }, contentPadding = pad) { Text("Screen control", color = cy, fontSize = 12.sp) }
                }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton({ pick.launch(arrayOf("*/*")) }) { Text("Import model") }
                        Button({
                            perms.launch(arrayOf(
                    Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS,
                    Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.READ_MEDIA_VIDEO,
                    Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_EXTERNAL_STORAGE
                ))
                        }) { Text("Activate") }
                    }
                }
            }
        }
    }
}

@Composable
fun Hud(status: String) {
    val t = rememberInfiniteTransition(label = "hud")
    val spin by t.animateFloat(0f, 360f, infiniteRepeatable(tween(14000, easing = LinearEasing)), label = "s")
    val pulse by t.animateFloat(0.88f, 1.08f, infiniteRepeatable(tween(1300), RepeatMode.Reverse), label = "p")
    val c = when (status) {
        "LISTENING" -> Color(0xFFFFC107)
        "THINKING" -> Color(0xFFFF5252)
        "SPEAKING" -> Color(0xFF69F0AE)
        else -> Color(0xFF00E5FF)
    }
    Canvas(Modifier.size(300.dp)) {
        val r = size.minDimension / 2
        drawCircle(c.copy(alpha = 0.22f), r * 0.36f * pulse)
        drawCircle(c, r * 0.30f * pulse, style = Stroke(5f))
        drawCircle(c.copy(alpha = 0.5f), r * 0.45f, style = Stroke(2f))
        rotate(spin) {
            drawCircle(c, r * 0.62f, style = Stroke(4f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(40f, 24f))))
        }
        rotate(-spin * 1.6f) {
            drawCircle(c.copy(alpha = 0.8f), r * 0.80f, style = Stroke(2f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 14f))))
        }
        rotate(spin * 0.5f) {
            drawCircle(c.copy(alpha = 0.4f), r * 0.97f, style = Stroke(3f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(90f, 50f))))
        }
    }
}
EOF
touch .ok2
