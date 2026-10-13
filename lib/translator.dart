// On-device translation between the app's languages.
//
// Uses ML Kit, which runs on the phone and needs no API key and no per-word
// cost. Each language needs a model downloaded once, over the phone's own
// connection; after that translation works offline.

import 'dart:async';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// How far along a language pair is.
enum TranslationStage {
  /// No output language chosen, so nothing to do.
  off,

  /// Waiting for a model to arrive.
  downloading,

  /// Ready to translate.
  ready,

  /// The model could not be fetched; the transcript stays untranslated.
  failed,
}

class TranslationStatus {
  const TranslationStatus(this.stage, {this.detail});

  final TranslationStage stage;
  final String? detail;

  bool get isReady => stage == TranslationStage.ready;
}

/// Translates finished transcript lines into the chosen output language.
class Translator {
  final StreamController<TranslationStatus> _statuses =
      StreamController<TranslationStatus>.broadcast();

  final _modelManager = OnDeviceTranslatorModelManager();

  OnDeviceTranslator? _translator;
  TranslateLanguage? _from;
  TranslateLanguage? _to;

  TranslationStatus _status = const TranslationStatus(TranslationStage.off);

  /// Bumped on every [setPair] call. Downloading a model takes a while, and a
  /// second call in the meantime must win: without this the slower of two
  /// overlapping calls would install its translator last and leave the pair
  /// pointing at a language the user has already moved off.
  int _generation = 0;

  TranslationStatus get status => _status;
  Stream<TranslationStatus> get statuses => _statuses.stream;

  /// Maps the app's language codes onto ML Kit's languages. Returns null for
  /// anything ML Kit cannot handle, so the caller can fall back gracefully.
  static TranslateLanguage? languageFor(String code) {
    switch (code) {
      case 'en':
        return TranslateLanguage.english;
      case 'fr':
        return TranslateLanguage.french;
      case 'sw':
        return TranslateLanguage.swahili;
      default:
        return null;
    }
  }

  void _emit(TranslationStatus next) {
    _status = next;
    if (!_statuses.isClosed) _statuses.add(next);
  }

  /// Prepares a translator for the given pair, downloading models if needed.
  /// Safe to call repeatedly; it rebuilds only when the pair actually changes.
  Future<void> setPair({
    required String fromCode,
    required String? toCode,
  }) async {
    final from = languageFor(fromCode);
    final to = toCode == null ? null : languageFor(toCode);
    final generation = ++_generation;

    if (to == null || from == null || from == to) {
      await _disposeTranslator();
      _from = null;
      _to = null;
      _emit(const TranslationStatus(TranslationStage.off));
      return;
    }
    if (from == _from && to == _to && _status.isReady) return;

    await _disposeTranslator();
    _from = from;
    _to = to;
    _emit(const TranslationStatus(
      TranslationStage.downloading,
      detail: 'Preparing translation…',
    ));

    try {
      // isWifiRequired: false so a phone on mobile data still works; the user
      // asked for it to use whatever connection is available.
      for (final language in [from, to]) {
        final code = language.bcpCode;
        final present = await _modelManager.isModelDownloaded(code);
        if (generation != _generation) return;
        if (!present) {
          _emit(TranslationStatus(
            TranslationStage.downloading,
            detail: 'Downloading $code language pack…',
          ));
          await _modelManager.downloadModel(code, isWifiRequired: false);
          if (generation != _generation) return;
        }
      }
      _translator = OnDeviceTranslator(
        sourceLanguage: from,
        targetLanguage: to,
      );
      _emit(const TranslationStatus(TranslationStage.ready));
    } catch (_) {
      if (generation != _generation) return;
      _translator = null;
      _emit(TranslationStatus(
        TranslationStage.failed,
        detail: 'Could not prepare translation. Check your connection.',
      ));
    }
  }

  /// Returns the translated text, or null when translation is unavailable so
  /// the caller can keep showing the original.
  Future<String?> translate(String text) async {
    final translator = _translator;
    if (translator == null || text.trim().isEmpty) return null;
    try {
      final result = await translator.translateText(text);
      return result.trim().isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  Future<void> _disposeTranslator() async {
    final translator = _translator;
    _translator = null;
    if (translator != null) await translator.close();
  }

  Future<void> dispose() async {
    await _disposeTranslator();
    await _statuses.close();
  }
}
