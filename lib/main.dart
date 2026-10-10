// Live Transcribe: free live speech-to-text for English, French and Swahili.
// Uses the phone's built-in speech recognition through the speech_to_text
// plugin, so there is no API key and no per-minute cost.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'device_audio.dart';
import 'link.dart';
import 'receive_page.dart';
import 'translator.dart';

void main() => runApp(const LiveTranscribeApp());

class Language {
  const Language(this.code, this.label, this.name, this.preferred);

  final String code;
  final String label;
  final String name;

  /// Locale ids to try first, best match first.
  final List<String> preferred;
}

const List<Language> languages = [
  Language('en', 'EN', 'English', ['en_US', 'en_GB']),
  Language('fr', 'FR', 'Français', ['fr_FR', 'fr_CA']),
  Language('sw', 'SW', 'Kiswahili', ['sw_TZ', 'sw_KE', 'sw']),
];

/// One finished line of the transcript, with its translation once that
/// arrives. Translation is filled in after the fact, so this stays mutable.
class Utterance {
  Utterance(this.original);

  final String original;
  String? translation;

  /// What should be read aloud: the translation when there is one.
  String get spoken => translation ?? original;
}

/// Errors that will not fix themselves, with the message to show for each.
const Map<String, String> fatalErrors = {
  'error_permission':
      'Microphone permission is off. Allow it in Settings > Apps > Live Transcribe.',
  'error_language_not_supported':
      'This language is not supported by the speech service on this phone.',
  'error_language_unavailable':
      'This language is not installed yet. Update the Google app, then try again.',
};

/// Errors Android raises during ordinary silence. Restart without comment.
const Set<String> quietErrors = {'error_no_match', 'error_speech_timeout'};

/// Longest wait between retries. Transcription runs until the user stops it,
/// so repeated failures slow the retries down but never end the session.
const Duration maxRetryDelay = Duration(seconds: 4);

/// How long a silence may last before Android ends the session and reports a
/// final result. Every restart re-opens the Bluetooth voice link, and that
/// churn provokes error_client, so this stays well above Android's default.
/// It cannot go too high either: a line is only committed, sent to listeners
/// and spoken once it is final, so a long value makes the link feel stuck.
const Duration pauseFor = Duration(seconds: 6);

/// Upper bound on a single session. Android stops well before this on its own;
/// it only keeps a wedged session from lasting forever.
const Duration listenFor = Duration(minutes: 10);

/// Android raises this when the recogniser is torn down underneath itself,
/// typically because the audio route changed. It needs a full reset and a
/// longer pause than other errors.
const String clientError = 'error_client';

class LiveTranscribeApp extends StatelessWidget {
  const LiveTranscribeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Transcribe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DDC97),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// Holds the two modes and the services they share. The speech engine and the
/// Bluetooth bridge each own a single platform channel, so exactly one of each
/// exists and both screens are handed the same instance.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final DeviceAudio _device = DeviceAudio();
  final Speaker _speaker = Speaker();

  int _tab = 0;

  @override
  void dispose() {
    _speaker.dispose();
    _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack so a live link keeps running while the other tab is open.
      body: IndexedStack(
        index: _tab,
        children: [
          TranscribePage(device: _device, speaker: _speaker),
          Scaffold(
            appBar: AppBar(title: const Text('Receive live')),
            body: SafeArea(child: ReceivePage(speaker: _speaker)),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.mic_rounded),
            label: 'Transcribe',
          ),
          NavigationDestination(
            icon: Icon(Icons.hearing_rounded),
            label: 'Receive',
          ),
        ],
      ),
    );
  }
}

class TranscribePage extends StatefulWidget {
  const TranscribePage({
    super.key,
    required this.device,
    required this.speaker,
  });

  final DeviceAudio device;
  final Speaker speaker;

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  final SpeechToText _speech = SpeechToText();
  final ScrollController _scroll = ScrollController();

  /// Finished lines of the transcript.
  final List<Utterance> _lines = [];

  /// Language code -> the locale id this phone actually uses for it.
  final Map<String, String> _localeIds = {};

  /// Words heard so far in the sentence still being spoken.
  String _partial = '';

  Language _language = languages.first;
  bool _ready = false;

  /// True while the user wants transcription running. Android ends a
  /// listening session after every pause, so we keep starting new ones.
  bool _wanted = false;

  /// True once the current session's text has been added to the transcript.
  bool _committed = false;

  /// Text we committed ourselves because no final result had arrived yet.
  String _lastFallback = '';

  int _failures = 0;
  String? _message;
  Timer? _restartTimer;
  Timer? _watchdog;

  DeviceAudio get _device => widget.device;
  Speaker get _speaker => widget.speaker;

  final Translator _translator = Translator();
  final LinkServer _link = LinkServer();
  StreamSubscription<int>? _linkClients;
  StreamSubscription<String>? _linkErrors;

  /// Addresses to show so a receiver knows where to connect.
  List<String> _addresses = const [];
  int _listeners = 0;

  /// True while sharing the transcript to other phones.
  bool _sharing = false;

  /// Speaks each finished line as it lands. Recognition pauses while it
  /// talks, so anything said during playback is missed.
  bool _autoSpeak = false;
  StreamSubscription<BluetoothState>? _btSub;
  StreamSubscription<bool>? _speakSub;
  StreamSubscription<TranslationStatus>? _translateSub;

  /// Language to translate into, or null to keep the spoken language.
  Language? _output;

  TranslationStatus _translation =
      const TranslationStatus(TranslationStage.off);

  BluetoothState _bt = const BluetoothState();

  /// True while the phone is reading the transcript out. Recognition pauses
  /// meanwhile, otherwise it would transcribe the phone's own voice.
  bool _speakingNow = false;

  /// False when the engine has no voice for the chosen language.
  bool _canSpeakLanguage = false;

  /// A problem worth showing that does not stop transcription.
  String? _notice;

  @override
  void initState() {
    super.initState();
    _init();
    _btSub = _device.states.listen(_onBluetoothState);
    _speakSub = _speaker.speakingChanges.listen(_onSpeakingChanged);
    _translateSub = _translator.statuses.listen((status) {
      if (!mounted) return;
      setState(() => _translation = status);
    });
    _linkClients = _link.clientCounts.listen((count) {
      if (!mounted) return;
      setState(() => _listeners = count);
    });
    _linkErrors = _link.errors.listen((message) {
      if (!mounted) return;
      setState(() => _notice = message);
    });
    // Safety net: if a session ended without telling us, start a new one.
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      final restartPending = _restartTimer?.isActive ?? false;
      if (_wanted &&
          _ready &&
          !_speakingNow &&
          !restartPending &&
          !_speech.isListening) {
        _startSession();
      }
    });
  }

  void _onBluetoothState(BluetoothState state) {
    if (!mounted) return;
    setState(() => _bt = state);
  }

  /// Recognition stays paused for as long as the phone is talking, then picks
  /// up again on its own so the user never has to restart it by hand.
  void _onSpeakingChanged(bool speaking) {
    if (!mounted) return;
    setState(() => _speakingNow = speaking);
    if (speaking) {
      _restartTimer?.cancel();
      _speech.stop();
    } else if (_wanted) {
      _scheduleRestart(const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _watchdog?.cancel();
    _btSub?.cancel();
    _speakSub?.cancel();
    _translateSub?.cancel();
    _linkClients?.cancel();
    _linkErrors?.cancel();
    _link.dispose();
    _translator.dispose();
    _speech.cancel();
    _speaker.stop();
    _device.keepAwake(false);
    // The speaker and the Bluetooth bridge belong to HomePage, which disposes
    // them; this screen only stops what it started.
    _scroll.dispose();
    super.dispose();
  }

  /// Starts or stops serving the transcript to other phones.
  Future<void> _toggleSharing() async {
    if (_sharing) {
      await _link.stop();
      setState(() {
        _sharing = false;
        _listeners = 0;
      });
      return;
    }
    final started = await _link.start(lang: _language.code);
    final addresses = await _link.localAddresses();
    if (!mounted) return;
    setState(() {
      _sharing = started;
      _addresses = addresses;
      if (!started) _notice = 'Could not start sharing on port $linkPort.';
    });
  }

  Future<void> _init() async {
    // Ask for Bluetooth before the speech plugin starts. The plugin decides
    // once, at initialise time, whether it may use a headset, and it only ever
    // requests that permission together with the microphone. With the mic
    // already granted it would never ask, leaving headsets permanently off.
    await _device.ensurePermission();
    await _device.refresh();

    bool ok = false;
    try {
      ok = await _speech.initialize(onStatus: _onStatus, onError: _onError);
      if (ok) {
        final available = await _speech.locales();
        final ids = available.map((locale) => locale.localeId).toList();
        for (final lang in languages) {
          _localeIds[lang.code] = _pickLocale(lang, ids);
        }
      }
    } catch (_) {
      ok = false;
    }
    await _refreshCanSpeak();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _message = ok
          ? null
          : 'Speech recognition is not available. Allow the microphone, and '
              'check that the Google app is installed and enabled.';
    });
  }

  Future<void> _refreshCanSpeak() async {
    final locale = _localeIds[_language.code] ?? _language.preferred.first;
    final can = await _speaker.canSpeak(locale);
    if (!mounted) return;
    setState(() => _canSpeakLanguage = can);
  }

  /// Finds the locale id the phone reports for a language. Phones differ on
  /// the format (en_US or en-US), and some report an incomplete list, so fall
  /// back to the usual id and let the recognizer decide.
  String _pickLocale(Language lang, List<String> ids) {
    String normalize(String id) => id.replaceAll('-', '_').toLowerCase();
    for (final want in lang.preferred) {
      for (final id in ids) {
        if (normalize(id) == want.toLowerCase()) return id;
      }
    }
    for (final id in ids) {
      final n = normalize(id);
      if (n == lang.code || n.startsWith('${lang.code}_')) return id;
    }
    return lang.preferred.first;
  }

  Future<void> _toggle() async {
    if (_wanted) {
      _restartTimer?.cancel();
      setState(() {
        _wanted = false;
        _notice = null;
      });
      await _device.keepAwake(false);
      await _speech.stop();
      // If no final result follows the stop, keep what was heard.
      Timer(const Duration(milliseconds: 2500), () {
        if (!_wanted && !_speech.isListening) _commitPartial();
      });
      return;
    }
    if (!_ready) {
      await _init();
      if (!_ready) return;
    }
    setState(() {
      _wanted = true;
      _failures = 0;
      _message = null;
      _notice = null;
    });
    await _device.keepAwake(true);
    await _startSession();
  }

  Future<void> _startSession() async {
    if (!_wanted || !_ready || _speakingNow || _speech.isListening) return;
    _commitPartial();
    _committed = false;
    try {
      await _speech.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          // Long sessions: each restart re-opens the Bluetooth voice link, and
          // that is what triggers error_client.
          pauseFor: pauseFor,
          listenFor: listenFor,
          localeId: _localeIds[_language.code] ?? _language.preferred.first,
          listenMode: ListenMode.dictation,
          partialResults: true,
          // Let the plugin keep the session rather than tearing it down on
          // every hiccup; this code restarts it when it really does end.
          cancelOnError: false,
          // false lets Android use the network recogniser, which is markedly
          // more accurate than the offline one and handles Kiswahili better.
          onDevice: false,
        ),
      );
    } catch (_) {
      _scheduleRestart(_retryDelay());
    }
    if (mounted) setState(() {});
  }

  void _scheduleRestart(Duration delay) {
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, _startSession);
  }

  /// Backs off as failures pile up, but keeps trying for as long as the user
  /// wants transcription running.
  Duration _retryDelay() {
    final ms = 300 * (_failures < 1 ? 1 : _failures);
    return Duration(
      milliseconds: ms > maxRetryDelay.inMilliseconds
          ? maxRetryDelay.inMilliseconds
          : ms,
    );
  }

  void _onResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    final words = result.recognizedWords.trim();
    setState(() {
      if (words.isNotEmpty) {
        // Recognition is working again; drop any retry warning.
        _failures = 0;
        _notice = null;
      }
      if (!result.finalResult) {
        // Android sometimes emits an empty partial mid-sentence. Taking it
        // literally would wipe the words heard so far, and the line would
        // then be dropped when the session ends rather than committed.
        if (!_committed && words.isNotEmpty) {
          _partial = words;
          // Send the sentence as it forms so the far end sees it live.
          _link.sendPartial(words, _language.code);
        }
        return;
      }
      final alreadySaved = _committed || words == _lastFallback;
      if (!alreadySaved && words.isNotEmpty) _addLine(words);
      _lastFallback = '';
      _committed = true;
      _partial = '';
    });
    _scrollToEnd();
  }

  /// Appends a finished line and, when an output language is set, fills in its
  /// translation as soon as it is ready.
  void _addLine(String text) {
    final line = Utterance(text);
    _lines.add(line);
    // Receivers translate for themselves, so they get the original text.
    _link.sendFinal(text, _language.code);

    if (!_translation.isReady) {
      _autoSpeakLine(line.original);
      return;
    }
    _translator.translate(text).then((translated) {
      if (!mounted) return;
      if (translated != null) {
        setState(() => line.translation = translated);
        _scrollToEnd();
      }
      _autoSpeakLine(line.spoken);
    });
  }

  /// Reads a finished line when auto-speak is on. Recognition is paused by
  /// the speaking callback and resumes once the phone stops talking.
  void _autoSpeakLine(String text) {
    if (!_autoSpeak || _speakingNow || text.trim().isEmpty) return;
    _speaker.speak(text, _speakLocale);
  }

  /// Moves an unfinished sentence into the transcript so it is not lost when
  /// a session ends before Android sends its final result.
  void _commitPartial() {
    if (_committed || _partial.isEmpty) return;
    final text = _partial;
    _committed = true;
    _lastFallback = text;
    _partial = '';
    _addLine(text);
    if (mounted) setState(() {});
  }

  void _onStatus(String status) {
    if (!mounted) return;
    if (status == SpeechToText.doneStatus) {
      _commitPartial();
      // Android ends a session at every pause. Start another unless the phone
      // is speaking, in which case resuming is handled when it finishes.
      if (_wanted && !_speakingNow) {
        _scheduleRestart(const Duration(milliseconds: 250));
      }
    }
    setState(() {});
  }

  void _onError(SpeechRecognitionError error) {
    if (!mounted) return;
    final code = error.errorMsg;
    final fatal = fatalErrors[code];
    if (fatal != null) {
      _halt(fatal);
      return;
    }
    if (quietErrors.contains(code)) {
      // Ordinary silence between sentences. Say nothing, start again at once.
      if (_wanted) _scheduleRestart(const Duration(milliseconds: 250));
      return;
    }

    // Anything else is reported but never ends the session: only the user
    // decides when transcription stops. Retries slow down as failures repeat
    // so a persistent fault does not spin the recogniser.
    _failures++;
    if (!_wanted) return;

    if (code == clientError) {
      // The recogniser is in a bad state, usually because the Bluetooth route
      // changed mid-session. Tear it down fully before trying again, otherwise
      // the next start fails the same way.
      _restartTimer?.cancel();
      _speech.cancel();
      setState(() => _notice = 'Audio route changed. Picking up again…');
      _scheduleRestart(const Duration(milliseconds: 1200));
      return;
    }

    setState(() {
      _notice = code.contains('network')
          ? 'Lost the speech service. Still trying…'
          : 'Recognition hiccup ($code). Still trying…';
    });
    _scheduleRestart(_retryDelay());
  }

  void _halt(String message) {
    _restartTimer?.cancel();
    _commitPartial();
    setState(() {
      _wanted = false;
      _message = message;
      _notice = null;
    });
    _device.keepAwake(false);
    _speech.cancel();
  }

  /// Reads the transcript aloud, or stops if it is already reading.
  Future<void> _toggleSpeech() async {
    if (_speakingNow) {
      await _speaker.stop();
      return;
    }
    final text = _spokenText.trim();
    if (text.isEmpty) return;
    final started = await _speaker.speak(text, _speakLocale);
    if (!started && mounted) {
      final name = (_output ?? _language).name;
      setState(() {
        _notice = _canSpeakLanguage
            ? 'The phone could not start speaking just now.'
            : 'No $name voice is installed. Add it in '
                'Settings > Accessibility > Text-to-speech.';
      });
    }
  }

  /// Chooses the language to translate into. Passing null keeps the spoken
  /// language and turns translation off.
  Future<void> _setOutput(Language? lang) async {
    setState(() {
      _output = lang;
      _notice = null;
    });
    await _speaker.stop();
    await _translator.setPair(
      fromCode: _language.code,
      toCode: lang?.code,
    );
    await _refreshCanSpeak();
  }

  Future<void> _setLanguage(Language lang) async {
    if (lang.code == _language.code) return;
    setState(() {
      _language = lang;
      _message = null;
      _notice = null;
      _failures = 0;
    });
    await _speaker.stop();
    // The pair changed, so the translator needs rebuilding for the new source.
    await _translator.setPair(
      fromCode: lang.code,
      toCode: _output?.code,
    );
    await _refreshCanSpeak();
    if (_wanted) {
      _restartTimer?.cancel();
      await _speech.stop();
      _scheduleRestart(const Duration(milliseconds: 400));
    }
  }

  /// The transcript for copying: the translation alongside each original when
  /// there is one, so nothing is lost.
  String get _fullText {
    final parts = <String>[];
    for (final line in _lines) {
      final translation = line.translation;
      parts.add(translation == null
          ? line.original
          : '${line.original}\n→ $translation');
    }
    if (_partial.isNotEmpty) parts.add(_partial);
    return parts.join('\n');
  }

  /// What the speaker button reads: the translated text when translating, so
  /// the phone speaks the output language.
  String get _spokenText {
    final parts = [for (final line in _lines) line.spoken];
    if (_partial.isNotEmpty && !_translation.isReady) parts.add(_partial);
    return parts.join('\n');
  }

  /// Locale the phone should speak in: the output language when translating.
  String get _speakLocale {
    final target = _output ?? _language;
    return _localeIds[target.code] ?? target.preferred.first;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _fullText));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Transcript copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _clear() {
    _link.sendClear();
    setState(() {
      _lines.clear();
      _partial = '';
      _lastFallback = '';
      // Ignore whatever is left of the sentence in progress.
      _committed = true;
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _lines.isNotEmpty || _partial.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcribe'),
        actions: [
          IconButton(
            tooltip: 'Copy transcript',
            onPressed: hasText ? _copy : null,
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: 'Clear transcript',
            onPressed: hasText ? _clear : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    for (final lang in languages)
                      ButtonSegment<String>(
                        value: lang.code,
                        label: Text(lang.name),
                      ),
                  ],
                  selected: {_language.code},
                  onSelectionChanged: (selection) => _setLanguage(
                    languages.firstWhere((l) => l.code == selection.first),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Text(
                    'to',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text('Same'),
                            selected: _output == null,
                            onSelected: (_) => _setOutput(null),
                          ),
                          for (final lang in languages)
                            if (lang.code != _language.code)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: ChoiceChip(
                                  label: Text(lang.name),
                                  selected: _output?.code == lang.code,
                                  onSelected: (_) => _setOutput(lang),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Icon(
                    _bt.hasHeadset
                        ? Icons.bluetooth_audio_rounded
                        : Icons.phone_android_rounded,
                    size: 18,
                    color: _bt.scoActive ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _bt.micLabel,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _bt.scoActive
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_bt.hasHeadset && !_bt.permission)
                    Text(
                      'no permission',
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  const SizedBox(width: 8),
                  // Auto-speak: each finished line read out as it lands.
                  Tooltip(
                    message: 'Speak each line as it is heard',
                    child: Row(
                      children: [
                        Icon(
                          Icons.record_voice_over_rounded,
                          size: 18,
                          color: _autoSpeak
                              ? scheme.tertiary
                              : scheme.onSurfaceVariant,
                        ),
                        Switch(
                          value: _autoSpeak,
                          onChanged: (value) {
                            setState(() => _autoSpeak = value);
                            if (!value) _speaker.stop();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Icon(
                    _sharing ? Icons.cast_connected_rounded : Icons.cast_rounded,
                    size: 18,
                    color: _sharing ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      !_sharing
                          ? 'Not sharing'
                          : _addresses.isEmpty
                              ? 'Sharing on port $linkPort · '
                                  '$_listeners listening'
                              : 'Share: ${_addresses.first} · '
                                  '$_listeners listening',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            _sharing ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _toggleSharing,
                    child: Text(_sharing ? 'Stop' : 'Share'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: hasText
                    ? SingleChildScrollView(
                        controller: _scroll,
                        child: SelectableText.rich(
                          TextSpan(
                            style: TextStyle(
                              fontSize: 22,
                              height: 1.45,
                              color: scheme.onSurface,
                            ),
                            children: [
                              for (final line in _lines) ...[
                                // When translating, the translation leads and
                                // the original stays underneath for checking.
                                TextSpan(
                                  text: line.translation ?? line.original,
                                ),
                                if (line.translation != null)
                                  TextSpan(
                                    text: '\n${line.original}',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: scheme.onSurfaceVariant,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                const TextSpan(text: '\n\n'),
                              ],
                              if (_partial.isNotEmpty)
                                TextSpan(
                                  text: _partial,
                                  style: TextStyle(
                                    color: scheme.onSurface.withAlpha(140),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          _wanted
                              ? 'Listening in ${_language.name}…'
                              : 'Pick a language, then tap the mic.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  _notice!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.tertiary, fontSize: 13),
                ),
              ),
            if (_translation.detail != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_translation.stage == TranslationStage.downloading)
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        _translation.detail!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: _translation.stage == TranslationStage.failed
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 84,
                        height: 84,
                        child: FilledButton(
                          onPressed: _toggle,
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: EdgeInsets.zero,
                            backgroundColor:
                                _wanted ? scheme.error : scheme.primary,
                            foregroundColor:
                                _wanted ? scheme.onError : scheme.onPrimary,
                          ),
                          child: Icon(
                            _wanted ? Icons.stop_rounded : Icons.mic_rounded,
                            size: 40,
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: FilledButton(
                          onPressed: hasText ? _toggleSpeech : null,
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: EdgeInsets.zero,
                            backgroundColor: _speakingNow
                                ? scheme.tertiary
                                : scheme.surfaceContainerHighest,
                            foregroundColor: _speakingNow
                                ? scheme.onTertiary
                                : scheme.onSurface,
                          ),
                          child: Icon(
                            _speakingNow
                                ? Icons.stop_rounded
                                : Icons.volume_up_rounded,
                            size: 28,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _speakingNow
                        ? 'Speaking ${(_output ?? _language).label} · paused'
                        : _wanted
                            ? 'Listening · ${_language.label}'
                                '${_output == null ? '' : ' → ${_output!.label}'}'
                                ' · tap to stop'
                            : 'Tap to start',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
