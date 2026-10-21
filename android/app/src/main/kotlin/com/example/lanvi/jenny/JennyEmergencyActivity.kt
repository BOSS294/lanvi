// Purpose: Show a high-visibility, dismissible local emergency alert from a saved contact.
// Integration: Opened by JennySmsReceiver notification; no AI/cloud needed to trigger the alert.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Red/navy strobe, alarm tone, local TTS, optional maximum alarm volume, double-tap dismiss.

package com.example.lanvi.jenny

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale

class JennyEmergencyActivity : Activity(), TextToSpeech.OnInitListener {
    private val handler = Handler(Looper.getMainLooper())
    private var flashRed = true
    private var toneGenerator: ToneGenerator? = null
    private var tts: TextToSpeech? = null
    private var audioManager: AudioManager? = null
    private var previousAlarmVolume: Int? = null
    private var dismissed = false
    private lateinit var gestureDetector: GestureDetector
    private lateinit var root: LinearLayout
    private lateinit var messageText: TextView
    private lateinit var sender: String
    private lateinit var message: String
    private val flashTask = object : Runnable {
        override fun run() {
            if (dismissed || !::root.isInitialized) return
            root.setBackgroundColor(if (flashRed) Color.rgb(160, 0, 24) else Color.rgb(5, 22, 62))
            flashRed = !flashRed
            handler.postDelayed(this, 420L)
        }
    }
    private val toneTask = object : Runnable {
        override fun run() {
            if (dismissed) return
            try { toneGenerator?.startTone(ToneGenerator.TONE_PROP_BEEP2, 260) } catch (_: Exception) { }
            handler.postDelayed(this, 1200L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (android.os.Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        sender = intent.getStringExtra("sender").orEmpty().ifBlank { "A saved contact" }
        message = intent.getStringExtra("message").orEmpty().ifBlank { "A message was marked as urgent." }
        buildScreen()
        flashTask.run()

        val prefs = getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE)
        val policy = JennyRuntimePolicy.read(this)
        val loudOverride = JennyRuntimePolicy.bool(policy, "emergencyMaxVolume", false)
        if (loudOverride) {
            audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val manager = audioManager!!
            previousAlarmVolume = manager.getStreamVolume(AudioManager.STREAM_ALARM)
            manager.setStreamVolume(AudioManager.STREAM_ALARM, manager.getStreamMaxVolume(AudioManager.STREAM_ALARM), AudioManager.FLAG_SHOW_UI)
        }
        try { toneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100) } catch (_: Exception) { }
        toneTask.run()
        tts = TextToSpeech(this, this)
    }

    private fun buildScreen() {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(42, 48, 42, 48)
            setBackgroundColor(Color.rgb(160, 0, 24))
        }
        val title = TextView(this).apply {
            text = "${JennyRuntimePolicy.assistantName(JennyRuntimePolicy.read(this@JennyEmergencyActivity)).uppercase()} · EMERGENCY"
            textSize = 23f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        val contact = TextView(this).apply {
            text = "Urgent message from $sender"
            textSize = 19f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 16)
        }
        messageText = TextView(this).apply {
            text = message
            textSize = 17f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 8, 0, 24)
        }
        val hint = TextView(this).apply {
            text = "Double-tap anywhere to stop the alert"
            textSize = 14f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 24)
        }
        val dismiss = Button(this).apply {
            text = "Dismiss emergency sound"
            setOnClickListener { dismissAlert() }
        }
        root.addView(title, LinearLayout.LayoutParams(-1, -2))
        root.addView(contact, LinearLayout.LayoutParams(-1, -2))
        root.addView(messageText, LinearLayout.LayoutParams(-1, -2))
        root.addView(hint, LinearLayout.LayoutParams(-1, -2))
        root.addView(dismiss, LinearLayout.LayoutParams(-1, -2))

        gestureDetector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean { dismissAlert(); return true }
        })
        setContentView(root)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (::gestureDetector.isInitialized && gestureDetector.onTouchEvent(event)) return true
        return super.dispatchTouchEvent(event)
    }

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) return
        val language = JennyRuntimePolicy.text(JennyRuntimePolicy.read(this), "voiceLanguage", "hi-IN")
        val locale = if (language == "en-IN") Locale("en", "IN") else Locale("hi", "IN")
        try { tts?.language = locale } catch (_: Exception) { }
        try {
            tts?.setSpeechRate(0.88f)
            tts?.setPitch(1.12f)
            tts?.speak("Mayank, emergency alert. ${JennyRuntimePolicy.assistantName(JennyRuntimePolicy.read(this))} received an urgent message from $sender. Please check your phone.", TextToSpeech.QUEUE_FLUSH, null, "lanvi-jenny-emergency")
        } catch (_: Exception) { }
    }

    private fun dismissAlert() {
        if (dismissed) return
        dismissed = true
        handler.removeCallbacksAndMessages(null)
        try { toneGenerator?.stopTone(); toneGenerator?.release() } catch (_: Exception) { }
        toneGenerator = null
        try { tts?.stop(); tts?.shutdown() } catch (_: Exception) { }
        tts = null
        val previous = previousAlarmVolume
        val manager = audioManager
        if (previous != null && manager != null) {
            try { manager.setStreamVolume(AudioManager.STREAM_ALARM, previous, 0) } catch (_: Exception) { }
        }
        finish()
    }

    override fun onBackPressed() {
        dismissAlert()
    }

    override fun onDestroy() {
        if (!dismissed) dismissAlert()
        super.onDestroy()
    }
}
