# Live Transcribe

Free live speech-to-text for English, French and Swahili on Android.
It uses the phone's built-in speech recognition and on-device translation,
so there is no API key and no cost.

- Transcribes continuously until you stop it.
- Works with a Bluetooth headset mic.
- Translates into another of the three languages, on the phone.
- Reads the text aloud, and can speak each line as it arrives.
- Sends the live transcript to other phones over Wi-Fi.

## Setup

```
flutter pub get
flutter run
```

Use a real phone. Emulators usually have no working speech service.

Allow the microphone when asked, and allow nearby devices if you want to use a
Bluetooth headset.

## Using it

### Transcribe tab

- **Top row** picks the language being spoken.
- **"to" row** picks the language to translate into, or `Same` for none.
  The translation is shown large with the original underneath it.
- **Mic row** shows whether the phone mic or a Bluetooth headset is in use, and
  the switch next to it speaks every finished line as it arrives.
- **Share row** serves the transcript to other phones; see below.
- **Big green button** starts and stops. **Speaker button** reads the
  transcript aloud in the output language.

Transcription keeps going until you stop it. Errors are reported in the status
line and retried; they no longer end the session.

### Receive tab

Shows what another phone hears.

1. On the sending phone, tap **Share**. It shows an address.
2. On the receiving phone, open **Receive**, type that address, tap
   **Connect**.
3. Choose the language to hear it in, and the **Show** and **Speak** switches.

Translation happens on the receiving phone, so two people can follow the same
speaker in different languages. Both phones must be on the same Wi-Fi or
hotspot.

## How it behaves

- Android ends a listening session after about six seconds of silence. A line
  is added to the transcript, sent to listeners and spoken only once that
  happens, so expect a short wait at the end of a sentence. The value is
  `pauseFor` in `lib/main.dart`: lower it for snappier results at the cost of
  more sentences being cut off mid-thought.
- You may hear the system beep each time listening restarts. Android does not
  let apps turn that off.
- Recognition uses the network when it can, which is noticeably more accurate
  than offline, and matters most for Kiswahili.
- Translation downloads a language pack once per language, roughly 30 MB each,
  over Wi-Fi or mobile data. After that it works offline.
- Bluetooth headset mics use the hands-free profile, which is narrowband.
  Accuracy is lower than the phone's own mic. A speaker with no microphone
  (A2DP only) cannot be used for input.
- Speaking aloud pauses recognition so the phone does not transcribe itself.
  Anything said during playback is missed. Two phones avoid this: one listens,
  the other speaks.

## If it does not work

- **"Speech recognition is not available"**: allow the microphone, and make
  sure the Google app is installed, enabled, and has microphone permission.
- **"Audio route changed. Picking up again…"**: Android reported
  `error_client`, which happens when the audio route moves under the
  recogniser, usually a Bluetooth headset connecting or another app taking the
  microphone, such as an incoming call. The app resets and carries on.
- **Swahili gives a language error**: update the Google app and
  "Speech Recognition & Synthesis" from the Play Store.
- **No voice when speaking aloud**: that language has no text-to-speech voice
  installed. Add it in Settings > Accessibility > Text-to-speech. Swahili is
  often missing.
- **A receiver cannot connect**: check both phones are on the same network.
  Some public and carrier networks block phone-to-phone connections; a
  personal hotspot avoids that.
- **Build error about minSdk**: set `minSdk = 21` or higher in
  `android/app/build.gradle.kts`.

## Testing the link from a PC

`tools/receive.ps1` prints the live transcript on a Windows PC, which is handy
when there is only one phone.

Over USB:

```
adb forward tcp:45678 tcp:45678
powershell -ExecutionPolicy Bypass -File tools\receive.ps1
```

Over Wi-Fi, pass the address the app shows:

```
powershell -ExecutionPolicy Bypass -File tools\receive.ps1 -RemoteHost 192.168.1.42
```

Tap **Share** in the app first, otherwise there is nothing to connect to.
Partial results print in grey, finished lines in white.

## The wire format

One JSON object per line, UTF-8, on TCP port 45678. The sender serves; any
number of receivers may connect. Only the original text is sent, so each
receiver translates for itself.

```json
{"t":"hello","lang":"en"}
{"t":"partial","text":"how are","lang":"en"}
{"t":"final","text":"how are you","lang":"en","seq":1}
{"t":"clear"}
```
