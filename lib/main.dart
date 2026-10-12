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
  Utterance(this.original, {this.speaker});

  final String original;

  /// Who said it, or null when this phone did. Shown so a conversation reads
  /// as a conversation rather than one run-on transcript.
  final String? speaker;

  String? translation;

  /// True when this phone's own microphone heard it.
  bool get mine => speaker == null;

  /// What should be read aloud: the translation when there is one.
  String get spoken => translation ?? original;
}

/// One line waiting its turn to be read aloud, with the voice to read it in.
class _Spoken {
  const _Spoken(this.text, this.locale);

  final String text;
  final String locale;
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

/// Longest wait between sessions that heard nothing. Android reports silence
/// after a few seconds, and restarting at once opens a fresh session on
/// Google's servers every time - a few minutes of quiet is enough for them to
/// start refusing, which surfaces as a network error. Backing off while
/// nothing is being said cuts that churn by more than half. It stays short
/// enough that the first word of the next sentence is not missed.
const Duration maxSilenceDelay = Duration(milliseconds: 1500);

/// The speech service refusing to answer is nearly always rate limiting
/// rather than a dead connection, and hammering it keeps it refusing. This
/// backs off much further than an ordinary fault.
const Duration maxNetworkDelay = Duration(seconds: 20);

/// How long the recogniser may do nothing at all before it is assumed wedged.
/// A working session reports something far more often than this: results while
/// someone is talking, and the end of a session within a few seconds of
/// silence. Longer than the network backoff, so a deliberate wait is never
/// mistaken for a stall.
const Duration stallTimeout = Duration(seconds: 25);

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

  /// Shared by both tabs: the Receive tab joins a conversation with it, and
  /// the Transcribe tab speaks back through the same connection. One socket,
  /// so nobody has to type the address twice.
  final LinkClient _link = LinkClient();

  int _tab = 0;

  @override
  void dispose() {
    _link.dispose();
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
          TranscribePage(device: _device, speaker: _speaker, link: _link),
          Scaffold(
            appBar: AppBar(title: const Text('Join a conversation')),
            body: SafeArea(child: ReceivePage(link: _link)),
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
          NavigationDestination(icon: Icon(Icons.forum_rounded), label: 'Join'),
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
    required this.link,
  });

  final DeviceAudio device;
  final Speaker speaker;

  /// The connection to a conversation this phone joined, if any. Owned by
  /// [HomePage]; this screen sends its own speech out through it.
  final LinkClient link;

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  final SpeechToText _speech = SpeechToText();
  final ScrollController _scroll = ScrollController();

  /// True while the transcript should follow new lines down. Reading means
  /// scrolling back up, and lines land fast enough - a partial result for
  /// every few words - that following them would drag the view off whatever
  /// is being read. Scrolling up lets go; scrolling back to the bottom, or
  /// the button that appears, takes hold again.
  bool _pinnedToEnd = true;

  /// Set while the scroll below is this code's doing, so the notifications it
  /// raises are not mistaken for the user scrolling away.
  bool _autoScrolling = false;

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

  /// Sessions in a row that heard nothing at all, and refusals in a row from
  /// the speech service. Both reset the moment a word is recognised, so a
  /// backoff never outlives the quiet that caused it.
  int _silences = 0;
  int _networkFailures = 0;

  String? _message;
  Timer? _restartTimer;
  Timer? _watchdog;

  /// When the recogniser last showed any sign of life. The plugin can be left
  /// believing a session is still open after the recogniser was torn down
  /// underneath it - the audio route changing is enough to do it - and every
  /// restart path then declines to act because it looks busy. This is how
  /// that is told apart from a session that is genuinely working.
  DateTime _lastActivity = DateTime.now();

  /// Keeps the last words of a stopped session when no final result follows
  /// the stop. Held so it can be cancelled with the screen.
  Timer? _stopFallback;

  DeviceAudio get _device => widget.device;
  Speaker get _speaker => widget.speaker;

  final Translator _translator = Translator();
  final LinkServer _link = LinkServer();
  StreamSubscription<int>? _linkClients;
  StreamSubscription<String>? _linkErrors;
  StreamSubscription<LinkMessage>? _hosted;
  StreamSubscription<LinkMessage>? _joined;
  StreamSubscription<LinkState>? _joinedStates;

  /// Translates what the other side says into the language this phone is
  /// reading. Separate from [_translator], which runs the other direction.
  final Translator _incoming = Translator();
  StreamSubscription<TranslationStatus>? _incomingSub;

  TranslationStatus _incomingStatus = const TranslationStatus(
    TranslationStage.off,
  );

  /// The inbound translator still being prepared, if any. A language pack can
  /// take a while to arrive, and the first line usually lands before it does;
  /// waiting on this is what gets that line translated rather than shown raw.
  Future<void>? _incomingPair;

  /// Language the other side is speaking, learnt from their messages.
  String _remoteLang = '';

  /// Their sentence still forming, and who is forming it.
  String _remotePartial = '';
  String _remoteSpeaker = '';

  /// The connection this phone joined, when it is a guest rather than a host.
  LinkClient get _peer => widget.link;

  /// Addresses to show so a receiver knows where to connect.
  List<String> _addresses = const [];
  int _listeners = 0;

  /// True while sharing the transcript to other phones.
  bool _sharing = false;

  /// Speaks each finished line as it lands - this phone's and the other
  /// side's. Recognition pauses while it talks, so anything said during
  /// playback is missed.
  bool _autoSpeak = false;

  /// Lines waiting to be read out. Speaking a new one while another is in
  /// progress cuts it off, so they take their turn.
  final List<_Spoken> _queue = [];

  /// Held from the moment a line is handed to the engine until it reports it
  /// has finished. [_speakingNow] is not enough on its own: it only turns
  /// true once the engine answers, and a line arriving in that gap would cut
  /// off the one just started.
  bool _reading = false;

  /// Releases [_reading] if the engine never reports back. It answers `speak`
  /// with success and then, on some phones, says nothing further - and with
  /// the latch stuck every later line would sit in the queue unread.
  Timer? _readingGuard;
  StreamSubscription<BluetoothState>? _btSub;
  StreamSubscription<bool>? _speakSub;
  StreamSubscription<TranslationStatus>? _translateSub;

  /// Language to translate into, or null to keep the spoken language.
  Language? _output;

  TranslationStatus _translation = const TranslationStatus(
    TranslationStage.off,
  );

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
    // Both directions arrive the same way: lines this phone hosts for its
    // guests, and lines from a conversation it joined as a guest.
    _hosted = _link.inbound.listen(_onRemote);
    _joined = _peer.messages.listen(_onRemote);
    _joinedStates = _peer.states.listen((_) {
      if (mounted) setState(() {});
    });
    _incomingSub = _incoming.statuses.listen((status) {
      if (!mounted) return;
      setState(() => _incomingStatus = status);
    });
    // Safety net: if a session ended without telling us, start a new one.
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_wanted || !_ready || _speakingNow) return;
      final restartPending = _restartTimer?.isActive ?? false;
      if (restartPending) return;
      if (!_speech.isListening) {
        // A session ended without telling us. Start another.
        _startSession();
        return;
      }
      // It says it is listening. If it has had nothing to report for this
      // long it is not listening at all, and nothing else will ever notice:
      // the app would sit showing "Listening" with the microphone shut.
      if (DateTime.now().difference(_lastActivity) > stallTimeout) {
        _forceRestart();
      }
    });
  }

  void _noteActivity() => _lastActivity = DateTime.now();

  /// Tears the recogniser down and starts it again, ignoring the plugin's own
  /// view of whether it is listening - that view is exactly what is wrong.
  Future<void> _forceRestart() async {
    // Before the await, so a slow teardown cannot be re-entered by the
    // watchdog ticking again underneath it.
    _noteActivity();
    _restartTimer?.cancel();
    try {
      await _speech.cancel();
    } catch (_) {
      // Already gone; starting again is what matters.
    }
    if (!mounted) return;
    await _startSession(force: true);
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
      return;
    }
    _releaseReading();
    // More lines waiting: read them before opening the microphone again,
    // otherwise each new line would cut off the one before it.
    if (_queue.isNotEmpty) {
      _drainSpeech();
      return;
    }
    if (_wanted) _scheduleRestart(const Duration(milliseconds: 300));
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _watchdog?.cancel();
    _stopFallback?.cancel();
    _readingGuard?.cancel();
    _btSub?.cancel();
    _speakSub?.cancel();
    _translateSub?.cancel();
    _linkClients?.cancel();
    _linkErrors?.cancel();
    _hosted?.cancel();
    _joined?.cancel();
    _joinedStates?.cancel();
    _incomingSub?.cancel();
    _link.dispose();
    // The joined connection belongs to HomePage and outlives this screen.
    _translator.dispose();
    _incoming.dispose();
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

    // Greets the host with this phone's language as soon as it joins, so the
    // first thing said here is translated rather than passed through raw.
    _peer.setLanguage(_language.code);

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
      _stopFallback?.cancel();
      _stopFallback = Timer(const Duration(milliseconds: 2500), () {
        if (!mounted) return;
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

  Future<void> _startSession({bool force = false}) async {
    if (!_wanted || !_ready || _speakingNow) return;
    if (!force && _speech.isListening) return;
    _commitPartial();
    _committed = false;
    _noteActivity();
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

  /// Grows while session after session hears nothing, and is capped low
  /// enough that speech starting again is still picked up promptly.
  Duration _silenceDelay() {
    final ms = 250 * _silences;
    return ms > maxSilenceDelay.inMilliseconds
        ? maxSilenceDelay
        : Duration(milliseconds: ms);
  }

  /// Doubles on every refusal: 2s, 4s, 8s, and so on up to the cap. The shift
  /// is clamped because a session left refusing for long enough would
  /// otherwise overflow to a negative delay, and a timer given one of those
  /// fires at once - the restart storm this is here to prevent.
  Duration _networkDelay() {
    final seconds = 1 << _networkFailures.clamp(1, 6);
    return seconds > maxNetworkDelay.inSeconds
        ? maxNetworkDelay
        : Duration(seconds: seconds);
  }

  /// Named in the advice shown when the service keeps refusing.
  String get _offlineHint =>
      '${_language.name} in Settings > General '
      'management > Voice input';

  void _onResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    _noteActivity();
    final words = result.recognizedWords.trim();
    setState(() {
      if (words.isNotEmpty) {
        // Recognition is working again; drop any retry warning.
        _failures = 0;
        _silences = 0;
        _networkFailures = 0;
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
          _peer.sendPartial(words, _language.code);
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
    // The far end translates for itself, so it gets the original text. Both
    // directions are served: guests of this phone, and the host it joined.
    _link.sendFinal(text, _language.code);
    _peer.sendFinal(text, _language.code);

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
  void _autoSpeakLine(String text) => _enqueueSpeech(text, _speakLocale);

  void _enqueueSpeech(String text, String locale) {
    if (!_autoSpeak || text.trim().isEmpty) return;
    _queue.add(_Spoken(text, locale));
    _drainSpeech();
  }

  Future<void> _drainSpeech() async {
    if (_reading || _speakingNow || _queue.isEmpty) return;
    _reading = true;
    final next = _queue.removeAt(0);
    final started = await _speaker.speak(next.text, next.locale);
    // The engine is reading it; the latch is released when it reports done.
    if (started) {
      _armReadingGuard(next.text);
      return;
    }
    _releaseReading();
    if (!mounted) return;
    // Nothing will call back, so keep things moving from here instead of
    // leaving the queue - and the microphone - stuck.
    if (_queue.isNotEmpty) {
      _drainSpeech();
    } else if (_wanted) {
      _scheduleRestart(const Duration(milliseconds: 300));
    }
  }

  /// Gives the engine a generous window to finish a line before assuming it
  /// never started. Scaled to the length of the text so a long line is not
  /// cut off part-way through.
  void _armReadingGuard(String text) {
    _readingGuard?.cancel();
    final seconds = 10 + text.length ~/ 8;
    _readingGuard = Timer(Duration(seconds: seconds), () {
      if (!_reading) return;
      // Nothing came back, so move on rather than leaving the queue - and the
      // microphone - waiting on a line that is not being read. Recognition
      // stays paused for as long as the phone is believed to be talking, so a
      // report that never arrives would otherwise leave the mic shut for good.
      _releaseReading();
      if (!mounted) return;
      if (_speakingNow) setState(() => _speakingNow = false);
      if (_queue.isNotEmpty) {
        _drainSpeech();
      } else if (_wanted) {
        _scheduleRestart(const Duration(milliseconds: 300));
      }
    });
  }

  void _releaseReading() {
    _readingGuard?.cancel();
    _readingGuard = null;
    _reading = false;
  }

  /// A line, or part of one, from the other side of the link. The same
  /// handler serves both roles: a host hearing its guests and a guest
  /// hearing the host.
  void _onRemote(LinkMessage message) {
    if (!mounted) return;
    if (message.lang.isNotEmpty) _setRemoteLang(message.lang);
    switch (message.kind) {
      case 'partial':
        // Partials are shown as they arrive but never translated: they change
        // constantly, and half a sentence translates badly.
        setState(() {
          _remotePartial = message.text;
          _remoteSpeaker = _speakerName(message.from);
        });
        break;
      case 'final':
        setState(() => _remotePartial = '');
        _addRemoteLine(message.text, _speakerName(message.from));
        break;
      case 'clear':
        // They cleared their transcript; drop their lines and keep ours.
        setState(() {
          _lines.removeWhere((line) => !line.mine);
          _remotePartial = '';
        });
        break;
    }
  }

  /// Lines from the host carry no name, so anything unnamed is the host.
  String _speakerName(String from) => from.isEmpty ? 'Host' : from;

  void _setRemoteLang(String code) {
    if (code == _remoteLang) return;
    _remoteLang = code;
    _incomingPair = _incoming.setPair(
      fromCode: code,
      toCode: _readingLang.code,
    );
  }

  /// Appends what the other side said, translated into the language this
  /// phone is reading and read aloud when auto-speak is on.
  Future<void> _addRemoteLine(String text, String speaker) async {
    if (text.trim().isEmpty) return;
    final line = Utterance(text, speaker: speaker);
    setState(() => _lines.add(line));
    _scrollToEnd();

    // Show the line at once, then wait for the translator if it is still
    // being set up; the alternative is reading the very first line of every
    // conversation out in a language the listener did not ask for.
    final pending = _incomingPair;
    if (pending != null && !_incomingStatus.isReady) {
      await pending;
      if (!mounted) return;
    }

    if (!_incomingStatus.isReady) {
      // Untranslated, so it is read in the language it was spoken in.
      _enqueueSpeech(line.original, _localeFor(_remoteLang));
      return;
    }
    final translated = await _incoming.translate(text);
    if (!mounted) return;
    if (translated != null) {
      setState(() => line.translation = translated);
      _scrollToEnd();
    }
    _enqueueSpeech(
      line.spoken,
      _localeFor(translated == null ? _remoteLang : _readingLang.code),
    );
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
    _noteActivity();
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
    _noteActivity();
    final code = error.errorMsg;
    final fatal = fatalErrors[code];
    if (fatal != null) {
      _halt(fatal);
      return;
    }
    if (quietErrors.contains(code)) {
      // Ordinary silence between sentences. Say nothing, and start again -
      // but a little slower each time, because every restart is a new session
      // on the speech service and a long quiet spell is what gets this phone
      // throttled. The first words spoken reset it to immediate again.
      _silences++;
      if (_wanted) _scheduleRestart(_silenceDelay());
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

    if (code.contains('network') || code.contains('server')) {
      _networkFailures++;
      final delay = _networkDelay();
      setState(() {
        _notice = _networkFailures < 3
            ? 'Lost the speech service. Picking up again…'
            : 'The speech service keeps refusing. Waiting '
                  '${delay.inSeconds}s before trying again - check the '
                  'connection, or install offline $_offlineHint.';
      });
      // Cancelled rather than merely stopped: a session left half-open is
      // counted against this phone while it waits.
      _restartTimer?.cancel();
      _speech.cancel();
      _scheduleRestart(delay);
      return;
    }

    setState(() => _notice = 'Recognition hiccup ($code). Still trying…');
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
    _queue.clear();
    _releaseReading();
    await _translator.setPair(fromCode: _language.code, toCode: lang?.code);
    // The other side is unchanged, but what this phone reads is not.
    await _setIncomingPair();
    await _refreshCanSpeak();
  }

  /// Points the inbound translator at whatever this phone is reading now.
  /// Does nothing until the other side has said something, since there is no
  /// source language to translate from before that.
  Future<void> _setIncomingPair() async {
    if (_remoteLang.isEmpty) return;
    final pending = _incoming.setPair(
      fromCode: _remoteLang,
      toCode: _readingLang.code,
    );
    _incomingPair = pending;
    await pending;
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
    // Anyone joined is translating from this language, so tell them - the
    // guests of this phone, and the host it joined.
    _link.setLanguage(lang.code);
    _peer.setLanguage(lang.code);
    // The pair changed, so the translator needs rebuilding for the new source.
    await _translator.setPair(fromCode: lang.code, toCode: _output?.code);
    await _setIncomingPair();
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
      // Named so a copied conversation still shows who said what.
      final who = line.mine ? '' : '${line.speaker}: ';
      final translation = line.translation;
      parts.add(
        translation == null
            ? '$who${line.original}'
            : '$who${line.original}\n→ $translation',
      );
    }
    if (_partial.isNotEmpty) parts.add(_partial);
    if (_remotePartial.isNotEmpty) {
      parts.add('$_remoteSpeaker: $_remotePartial');
    }
    return parts.join('\n');
  }

  /// What the speaker button reads: the translated text when translating, so
  /// the phone speaks the output language.
  String get _spokenText {
    final parts = [for (final line in _lines) line.spoken];
    if (_partial.isNotEmpty && !_translation.isReady) parts.add(_partial);
    return parts.join('\n');
  }

  /// The language this phone shows and speaks: the output language when
  /// translating, otherwise the one being spoken into it.
  Language get _readingLang => _output ?? _language;

  /// Locale the phone should speak in: the output language when translating.
  String get _speakLocale => _localeFor(_readingLang.code);

  /// The locale id this phone uses for a language code, falling back to the
  /// usual id for a language it was never asked about.
  String _localeFor(String code) {
    final known = _localeIds[code];
    if (known != null) return known;
    for (final lang in languages) {
      if (lang.code == code) return lang.preferred.first;
    }
    return code;
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
    _peer.sendClear();
    _queue.clear();
    _speaker.stop();
    _releaseReading();
    setState(() {
      _lines.clear();
      _partial = '';
      _remotePartial = '';
      _lastFallback = '';
      // Ignore whatever is left of the sentence in progress.
      _committed = true;
      // Nothing left to read back, so follow along again.
      _pinnedToEnd = true;
    });
    // Start a fresh session. The flag above makes the running one discard
    // everything it still has to say, so without this nothing would be
    // transcribed until the next silence ended it on its own.
    if (_wanted) {
      _restartTimer?.cancel();
      _speech.cancel();
      _scheduleRestart(const Duration(milliseconds: 300));
    }
  }

  void _scrollToEnd() {
    if (!_pinnedToEnd) return;
    _jumpToEnd();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _autoScrolling = true;
      _scroll
          .animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          )
          .whenComplete(() => _autoScrolling = false);
    });
  }

  /// How close to the bottom still counts as following along. A line and a
  /// half, so a stray flick does not detach the view for good.
  static const double _stickyMargin = 80;

  /// Watches who is doing the scrolling. Anything this code started is
  /// ignored; the rest decides whether new lines are still being followed.
  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (_autoScrolling) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final position = notification.metrics;
    final atEnd = position.pixels >= position.maxScrollExtent - _stickyMargin;
    if (atEnd != _pinnedToEnd && mounted) {
      setState(() => _pinnedToEnd = atEnd);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText =
        _lines.isNotEmpty || _partial.isNotEmpty || _remotePartial.isNotEmpty;

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
                  Text('to', style: TextStyle(color: scheme.onSurfaceVariant)),
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
                    color: _bt.scoActive
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
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
                    message: 'Speak each line aloud, yours and theirs',
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
                            if (!value) {
                              _queue.clear();
                              _releaseReading();
                              _speaker.stop();
                            }
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
                    _sharing
                        ? Icons.cast_connected_rounded
                        : Icons.cast_rounded,
                    size: 18,
                    color: _sharing ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      !_sharing
                          ? 'Not hosting'
                          : _addresses.isEmpty
                          ? 'No Wi-Fi. Join a network or start a hotspot.'
                          // Every usable address, so the other phone can
                          // be pointed at whichever one it shares.
                          : '${_addresses.join('  ·  ')}  ·  '
                                '$_listeners joined',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: _sharing
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _toggleSharing,
                    child: Text(_sharing ? 'Stop' : 'Host'),
                  ),
                ],
              ),
            ),
            // Shown only once this phone has joined someone else's
            // conversation, so it is clear the microphone is going out.
            if (_peer.state != LinkState.idle)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    Icon(
                      _peer.connected
                          ? Icons.swap_horiz_rounded
                          : Icons.link_off_rounded,
                      size: 18,
                      color: _peer.connected
                          ? scheme.tertiary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _peer.connected
                            ? 'Two-way with ${_peer.host} - they hear you'
                            : _peer.detail ?? 'Not joined',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: _peer.connected
                              ? scheme.tertiary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
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
                    ? NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: Stack(
                          children: [
                            SingleChildScrollView(
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
                                      // Named only when someone else said it, so
                                      // the two sides of a conversation stay apart
                                      // without a label on every line.
                                      if (!line.mine)
                                        TextSpan(
                                          text: '${line.speaker}  ',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: scheme.tertiary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      // When translating, the translation leads and
                                      // the original stays underneath for checking.
                                      TextSpan(
                                        text: line.translation ?? line.original,
                                        style: line.mine
                                            ? null
                                            : TextStyle(color: scheme.tertiary),
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
                                          color: scheme.onSurface.withAlpha(
                                            140,
                                          ),
                                        ),
                                      ),
                                    if (_remotePartial.isNotEmpty) ...[
                                      if (_partial.isNotEmpty)
                                        const TextSpan(text: '\n\n'),
                                      TextSpan(
                                        text: '$_remoteSpeaker  ',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: scheme.tertiary.withAlpha(150),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      TextSpan(
                                        text: _remotePartial,
                                        style: TextStyle(
                                          color: scheme.tertiary.withAlpha(150),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            // Appears only once the view has been scrolled
                            // back, so new lines never steal the page from
                            // under whoever is reading it.
                            if (!_pinnedToEnd)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: FilledButton.tonalIcon(
                                  onPressed: () {
                                    setState(() => _pinnedToEnd = true);
                                    _jumpToEnd();
                                  },
                                  icon: const Icon(
                                    Icons.arrow_downward_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Latest'),
                                ),
                              ),
                          ],
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
                            backgroundColor: _wanted
                                ? scheme.error
                                : scheme.primary,
                            foregroundColor: _wanted
                                ? scheme.onError
                                : scheme.onPrimary,
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
