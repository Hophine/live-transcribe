# Live Transcribe

Free live speech-to-text for English, French and Swahili on Android.
It uses the phone's built-in speech recognition, so there is no API key and no cost.

## Setup

1. Create the project and add the speech plugin:

   ```
   flutter create --platforms=android live_transcribe
   cd live_transcribe
   flutter pub add speech_to_text
   ```

2. Replace `lib/main.dart` with the `main.dart` from this folder.

3. Open `android/app/src/main/AndroidManifest.xml` and paste these lines
   directly above the `<application` tag:

   ```xml
   <uses-permission android:name="android.permission.RECORD_AUDIO"/>
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.BLUETOOTH"/>
   <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
   <queries>
       <intent>
           <action android:name="android.speech.RecognitionService" />
       </intent>
   </queries>
   ```

4. Plug in a real Android phone and run:

   ```
   flutter run
   ```

   Use a real phone. Emulators often have no working speech service.

## If it does not work

- **"Speech recognition is not available"**: allow the microphone, and make sure
  the Google app is installed, enabled, and has microphone permission.
- **Swahili gives a language error**: update the Google app and
  "Speech Recognition & Synthesis" from the Play Store.
- **Build error about minSdk**: set `minSdk = 21` or higher in
  `android/app/build.gradle` (or `build.gradle.kts`).

## How it behaves

- Android stops listening after each pause in speech. The app starts listening
  again by itself, so you may hear the system beep each time it restarts.
  Android does not let apps turn that beep off.
- It needs internet for the best results.
- Text in grey is still being recognised. It turns white once the sentence is final.
