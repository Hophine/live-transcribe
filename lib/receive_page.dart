// The receiving end of a live link: shows what the other phone hears and,
// optionally, reads it aloud.
//
// Translation happens here rather than on the sender, so each listener picks
// their own language independently.

import 'dart:async';

import 'package:flutter/material.dart';

import 'device_audio.dart';
import 'link.dart';
import 'main.dart' show Language, Utterance, languages;
import 'translator.dart';

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key, required this.speaker});

  /// Shared with the rest of the app: only one engine may be bound at a time.
  final Speaker speaker;

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  final LinkClient _link = LinkClient();
  final Translator _translator = Translator();
  final TextEditingController _host = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<Utterance> _lines = [];

  StreamSubscription<LinkMessage>? _messages;
  StreamSubscription<LinkState>? _states;
  StreamSubscription<TranslationStatus>? _translateStatus;

  /// Language the sender is speaking, from its greeting or its messages.
  String _incomingLang = 'en';

  /// Chosen output language, or null to show it exactly as spoken.
  Language? _output;

  TranslationStatus _translation =
      const TranslationStatus(TranslationStage.off);

  /// Words still forming on the sender's side.
  String _partial = '';

  bool _showText = true;
  bool _speakAloud = false;

  /// Queue so sentences are read in order instead of cutting each other off.
  final List<String> _toSpeak = [];
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    _messages = _link.messages.listen(_onMessage);
    _states = _link.states.listen((_) {
      if (mounted) setState(() {});
    });
    _translateStatus = _translator.statuses.listen((status) {
      if (mounted) setState(() => _translation = status);
    });
    widget.speaker.speakingChanges.listen(_onSpeakingChanged);
  }

  @override
  void dispose() {
    _messages?.cancel();
    _states?.cancel();
    _translateStatus?.cancel();
    _link.dispose();
    _translator.dispose();
    _host.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onMessage(LinkMessage message) {
    switch (message.kind) {
      case 'hello':
        if (message.lang.isNotEmpty) _setIncomingLang(message.lang);
        break;
      case 'partial':
        if (message.lang.isNotEmpty) _setIncomingLang(message.lang);
        // Partials are shown untranslated: they change constantly, and
        // translating half a sentence gives a worse result than waiting.
        setState(() => _partial = message.text);
        break;
      case 'final':
        if (message.lang.isNotEmpty) _setIncomingLang(message.lang);
        setState(() => _partial = '');
        _addLine(message.text);
        break;
      case 'clear':
        setState(() {
          _lines.clear();
          _partial = '';
        });
        break;
    }
  }

  void _setIncomingLang(String code) {
    if (code == _incomingLang) return;
    _incomingLang = code;
    // The source changed, so the translator needs rebuilding.
    _translator.setPair(fromCode: code, toCode: _output?.code);
  }

  void _addLine(String text) {
    if (text.trim().isEmpty) return;
    final line = Utterance(text);
    setState(() => _lines.add(line));
    _scrollToEnd();

    if (!_translation.isReady) {
      _enqueueSpeech(line.original, _incomingLang);
      return;
    }
    _translator.translate(text).then((translated) {
      if (!mounted) return;
      if (translated != null) {
        setState(() => line.translation = translated);
        _scrollToEnd();
      }
      _enqueueSpeech(line.spoken, _output?.code ?? _incomingLang);
    });
  }

  /// Reads lines one at a time. Speaking a new line while one is in progress
  /// would cut it off, so they wait their turn.
  void _enqueueSpeech(String text, String langCode) {
    if (!_speakAloud || text.trim().isEmpty) return;
    _toSpeak.add(text);
    _drainSpeech(langCode);
  }

  Future<void> _drainSpeech(String langCode) async {
    if (_speaking || _toSpeak.isEmpty) return;
    _speaking = true;
    final text = _toSpeak.removeAt(0);
    final locale = _localeFor(langCode);
    final started = await widget.speaker.speak(text, locale);
    if (!started) {
      // Nothing will come back to release the queue, so do it here.
      _speaking = false;
      if (mounted) _drainSpeech(langCode);
    }
  }

  void _onSpeakingChanged(bool speaking) {
    if (speaking || !mounted) return;
    _speaking = false;
    _drainSpeech(_output?.code ?? _incomingLang);
  }

  String _localeFor(String code) {
    for (final lang in languages) {
      if (lang.code == code) return lang.preferred.first;
    }
    return code;
  }

  Future<void> _setOutput(Language? lang) async {
    setState(() => _output = lang);
    await _translator.setPair(
      fromCode: _incomingLang,
      toCode: lang?.code,
    );
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

  String get _statusText {
    switch (_link.state) {
      case LinkState.idle:
        return 'Enter the address shown on the sending phone.';
      case LinkState.connecting:
      case LinkState.connected:
      case LinkState.failed:
        return _link.detail ?? '';
    }
  }

  Color _statusColour(ColorScheme scheme) {
    switch (_link.state) {
      case LinkState.connected:
        return scheme.primary;
      case LinkState.failed:
        return scheme.error;
      case LinkState.connecting:
      case LinkState.idle:
        return scheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connected = _link.state == LinkState.connected;
    final hasText = _lines.isNotEmpty || _partial.isNotEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _host,
                  keyboardType: TextInputType.text,
                  decoration: const InputDecoration(
                    labelText: 'Sender address',
                    hintText: '192.168.1.42',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) => _link.connect(value),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: connected
                    ? _link.disconnect
                    : () => _link.connect(_host.text),
                child: Text(connected ? 'Stop' : 'Connect'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                connected ? Icons.link_rounded : Icons.link_off_rounded,
                size: 16,
                color: _statusColour(scheme),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusText,
                  style: TextStyle(fontSize: 13, color: _statusColour(scheme)),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
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
                        label: const Text('As spoken'),
                        selected: _output == null,
                        onSelected: (_) => _setOutput(null),
                      ),
                      for (final lang in languages)
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
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  value: _showText,
                  onChanged: (value) => setState(() => _showText = value),
                  title: const Text('Show', style: TextStyle(fontSize: 13)),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  value: _speakAloud,
                  onChanged: (value) {
                    setState(() => _speakAloud = value);
                    if (!value) {
                      _toSpeak.clear();
                      widget.speaker.stop();
                    }
                  },
                  title: const Text('Speak', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
        if (_translation.detail != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
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
        Expanded(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: !_showText
                ? Center(
                    child: Text(
                      _speakAloud
                          ? 'Listening aloud. Text hidden.'
                          : 'Text hidden and speech off.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : hasText
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
                          connected
                              ? 'Connected. Waiting for speech…'
                              : 'Not connected.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
          ),
        ),
      ],
    );
  }
}
