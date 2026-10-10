// Live Transcribe: free live speech-to-text for English, French and Swahili.
// Uses the phone's built-in speech recognition through the speech_to_text
// plugin, so there is no API key and no per-minute cost.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

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
      home: const TranscribePage(),
    );
  }
}

class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  final SpeechToText _speech = SpeechToText();
  final ScrollController _scroll = ScrollController();

  /// Finished lines of the transcript.
  final List<String> _lines = [];

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

  @override
  void initState() {
    super.initState();
    _init();
    // Safety net: if a session ended without telling us, start a new one.
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      final restartPending = _restartTimer?.isActive ?? false;
      if (_wanted && _ready && !restartPending && !_speech.isListening) {
        _startSession();
      }
    });
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _watchdog?.cancel();
    _speech.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
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
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _message = ok
          ? null
          : 'Speech recognition is not available. Allow the microphone, and '
              'check that the Google app is installed and enabled.';
    });
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
      setState(() => _wanted = false);
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
    });
    await _startSession();
  }

  Future<void> _startSession() async {
    if (!_wanted || !_ready || _speech.isListening) return;
    _commitPartial();
    _committed = false;
    try {
      await _speech.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          localeId: _localeIds[_language.code] ?? _language.preferred.first,
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      _scheduleRestart(const Duration(seconds: 1));
    }
    if (mounted) setState(() {});
  }

  void _scheduleRestart(Duration delay) {
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, _startSession);
  }

  void _onResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    final words = result.recognizedWords.trim();
    setState(() {
      if (words.isNotEmpty) _failures = 0;
      if (!result.finalResult) {
        if (!_committed) _partial = words;
        return;
      }
      final alreadySaved = _committed || words == _lastFallback;
      if (!alreadySaved && words.isNotEmpty) _lines.add(words);
      _lastFallback = '';
      _committed = true;
      _partial = '';
    });
    _scrollToEnd();
  }

  /// Moves an unfinished sentence into the transcript so it is not lost when
  /// a session ends before Android sends its final result.
  void _commitPartial() {
    if (_committed || _partial.isEmpty) return;
    final text = _partial;
    _committed = true;
    _lastFallback = text;
    _partial = '';
    _lines.add(text);
    if (mounted) setState(() {});
  }

  void _onStatus(String status) {
    if (!mounted) return;
    if (status == SpeechToText.doneStatus) {
      _commitPartial();
      if (_wanted) _scheduleRestart(const Duration(milliseconds: 250));
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
    if (!quietErrors.contains(code)) {
      _failures++;
      if (_failures >= 5) {
        _halt(code.contains('network')
            ? 'No connection to the speech service. Check your internet.'
            : 'Speech recognition keeps failing ($code).');
        return;
      }
    }
    if (_wanted) {
      _scheduleRestart(
        Duration(milliseconds: quietErrors.contains(code) ? 250 : 800),
      );
    }
  }

  void _halt(String message) {
    _restartTimer?.cancel();
    _commitPartial();
    setState(() {
      _wanted = false;
      _message = message;
    });
    _speech.cancel();
  }

  Future<void> _setLanguage(Language lang) async {
    if (lang.code == _language.code) return;
    setState(() {
      _language = lang;
      _message = null;
      _failures = 0;
    });
    if (_wanted) {
      _restartTimer?.cancel();
      await _speech.stop();
      _scheduleRestart(const Duration(milliseconds: 400));
    }
  }

  String get _fullText =>
      [..._lines, if (_partial.isNotEmpty) _partial].join('\n');

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
                              for (final line in _lines)
                                TextSpan(text: '$line\n\n'),
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
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
                  const SizedBox(height: 10),
                  Text(
                    _wanted ? 'Listening · ${_language.label}' : 'Tap to start',
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
