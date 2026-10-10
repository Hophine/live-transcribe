// Dart side of the native audio bridges: Bluetooth headset state, the screen
// lock, and speaking text aloud.

import 'dart:async';

import 'package:flutter/services.dart';

/// What the phone reports about the Bluetooth headset right now.
class BluetoothState {
  const BluetoothState({
    this.permission = false,
    this.adapterOn = false,
    this.headset,
    this.scoActive = false,
  });

  /// BLUETOOTH_CONNECT. Without it the speech plugin silently ignores headsets.
  final bool permission;
  final bool adapterOn;

  /// Name of the connected headset, or null when there is none.
  final String? headset;

  /// True once the headset mic is actually carrying audio. Being connected is
  /// not enough: the voice link opens only when recognition starts.
  final bool scoActive;

  bool get hasHeadset => headset != null;

  /// What the user should see as the current microphone.
  String get micLabel {
    if (!hasHeadset) return 'Phone mic';
    return scoActive ? '$headset · live' : '$headset';
  }

  factory BluetoothState.fromMap(Map<dynamic, dynamic> map) {
    return BluetoothState(
      permission: map['permission'] as bool? ?? false,
      adapterOn: map['adapterOn'] as bool? ?? false,
      headset: map['headset'] as String?,
      scoActive: map['scoActive'] as bool? ?? false,
    );
  }
}

/// Bluetooth headset state and the screen-awake flag.
class DeviceAudio {
  DeviceAudio() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') {
        final args = call.arguments;
        if (args is Map) _emit(BluetoothState.fromMap(args));
      }
      return null;
    });
  }

  static const MethodChannel _channel = MethodChannel('live_transcribe/device');

  final StreamController<BluetoothState> _states =
      StreamController<BluetoothState>.broadcast();

  BluetoothState _state = const BluetoothState();

  BluetoothState get state => _state;
  Stream<BluetoothState> get states => _states.stream;

  void _emit(BluetoothState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// Asks for BLUETOOTH_CONNECT if it is not granted yet. This must happen
  /// before the speech plugin initialises, because the plugin decides once at
  /// start-up whether headsets are usable and never revisits it.
  Future<bool> ensurePermission() async {
    try {
      final has = await _channel.invokeMethod<bool>('hasPermission') ?? false;
      if (has) return true;
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<BluetoothState> refresh() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('state');
      if (map != null) _emit(BluetoothState.fromMap(map));
    } on PlatformException {
      // Leave the last known state in place.
    } on MissingPluginException {
      // Running without the native side; stay on the defaults.
    }
    return _state;
  }

  Future<void> keepAwake(bool on) async {
    try {
      await _channel.invokeMethod<bool>('keepAwake', on);
    } on PlatformException {
      // Not fatal: the screen may just time out as usual.
    } on MissingPluginException {
      // Same.
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _states.close();
  }
}

/// Speaks text with the phone's built-in engine.
class Speaker {
  Speaker() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ready':
          _ready = call.arguments as bool? ?? false;
          break;
        case 'speaking':
          final value = call.arguments as bool? ?? false;
          _speaking = value;
          if (!_speakingEvents.isClosed) _speakingEvents.add(value);
          break;
      }
      return null;
    });
  }

  static const MethodChannel _channel = MethodChannel('live_transcribe/tts');

  final StreamController<bool> _speakingEvents =
      StreamController<bool>.broadcast();

  bool _ready = false;
  bool _speaking = false;

  bool get ready => _ready;
  bool get speaking => _speaking;

  /// Fires true when speech starts and false when it stops, so the caller can
  /// pause the recogniser and resume it afterwards.
  Stream<bool> get speakingChanges => _speakingEvents.stream;

  Future<bool> canSpeak(String localeId) async {
    try {
      return await _channel
              .invokeMethod<bool>('canSpeak', {'locale': localeId}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Returns false when the engine refused the text, so the UI can explain
  /// instead of appearing to do nothing.
  Future<bool> speak(String text, String localeId) async {
    try {
      return await _channel.invokeMethod<bool>('speak', {
            'text': text,
            'locale': localeId,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException {
      // Nothing to stop.
    } on MissingPluginException {
      // Same.
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _speakingEvents.close();
  }
}
