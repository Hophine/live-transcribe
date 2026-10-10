package com.example.live_transcribe

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

// Speaks text with Android's built-in engine.
//
// Uses the platform TextToSpeech directly rather than a plugin so the app adds
// no new dependencies. Playback goes out on the media stream, which means a
// connected Bluetooth headset gets it over A2DP automatically.
class TtsBridge(messenger: BinaryMessenger, context: Context) {

    private val channel = MethodChannel(messenger, "live_transcribe/tts")

    // Set once the engine has reported success; calls before that are rejected
    // rather than silently dropped.
    private var ready = false
    private var engine: TextToSpeech? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> speak(call.argument<String>("text"), call.argument<String>("locale"), result)
                "stop" -> {
                    engine?.stop()
                    result.success(true)
                }
                "canSpeak" -> result.success(canSpeak(call.argument<String>("locale")))
                else -> result.notImplemented()
            }
        }

        engine = TextToSpeech(context) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (ready) attachProgressListener()
            channel.invokeMethod("ready", ready)
        }
    }

    private fun attachProgressListener() {
        engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                channel.invokeMethod("speaking", true)
            }

            override fun onDone(utteranceId: String?) {
                channel.invokeMethod("speaking", false)
            }

            @Deprecated("Required by the base class; the newer overload forwards here.")
            override fun onError(utteranceId: String?) {
                channel.invokeMethod("speaking", false)
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                channel.invokeMethod("speaking", false)
            }
        })
    }

    // Android reports a locale as missing data, missing voice, or not supported.
    // Only a positive result means it will actually speak.
    private fun canSpeak(localeId: String?): Boolean {
        val tts = engine ?: return false
        if (!ready) return false
        val locale = toLocale(localeId) ?: return false
        val status = tts.isLanguageAvailable(locale)
        return status == TextToSpeech.LANG_AVAILABLE ||
            status == TextToSpeech.LANG_COUNTRY_AVAILABLE ||
            status == TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE
    }

    private fun speak(text: String?, localeId: String?, result: MethodChannel.Result) {
        val tts = engine
        if (tts == null || !ready) {
            result.error("not_ready", "The speech engine is not ready yet.", null)
            return
        }
        if (text.isNullOrBlank()) {
            result.success(false)
            return
        }
        toLocale(localeId)?.let { tts.language = it }
        // QUEUE_FLUSH so a new request replaces whatever is playing instead of
        // queueing behind it.
        val queued = tts.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "transcript")
        result.success(queued == TextToSpeech.SUCCESS)
    }

    // Accepts the locale ids the speech recogniser reports, which use either
    // en_US or en-US depending on the phone.
    private fun toLocale(localeId: String?): Locale? {
        if (localeId.isNullOrBlank()) return null
        val parts = localeId.replace('-', '_').split('_')
        return when {
            parts.size >= 2 -> Locale(parts[0], parts[1])
            else -> Locale(parts[0])
        }
    }

    fun release() {
        channel.setMethodCallHandler(null)
        engine?.stop()
        engine?.shutdown()
        engine = null
        ready = false
    }
}
