// Joining end of a live link: points this phone at the one hosting a
// conversation.
//
// This screen only opens and closes the connection. The conversation itself -
// what they say, what you say, translation and reading aloud - lives on the
// Transcribe tab, which sends this phone's speech out over the same socket
// and shows both sides in one transcript. Keeping it in one place is what
// makes the link two-way: two transcripts of the same conversation would
// double every line and read each one out twice.

import 'dart:async';

import 'package:flutter/material.dart';

import 'link.dart';

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key, required this.link});

  /// The app's one connection, shared with the Transcribe tab.
  final LinkClient link;

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  final TextEditingController _host = TextEditingController();

  StreamSubscription<LinkState>? _states;

  LinkClient get _link => widget.link;

  @override
  void initState() {
    super.initState();
    // The connection may already be up from an earlier visit to this tab.
    _host.text = _link.host ?? '';
    _states = _link.states.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _states?.cancel();
    // The connection belongs to the app, not to this screen: leaving it open
    // is what lets the Transcribe tab keep talking and listening.
    _host.dispose();
    super.dispose();
  }

  String get _statusText {
    switch (_link.state) {
      case LinkState.idle:
        return 'Enter the address shown on the hosting phone.';
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          'Join a conversation someone else is hosting. Once joined, you both '
          'speak and both see and hear the other - on the Transcribe tab.',
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _host,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Host address',
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
              child: Text(connected ? 'Leave' : 'Join'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
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
        if (connected) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Icon(Icons.swap_horiz_rounded, color: scheme.tertiary),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Joined. Open the Transcribe tab, pick the language you '
                    'want to read and hear, and tap the mic to talk.',
                    style: TextStyle(fontSize: 15, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          'To be the host instead, use Host on the Transcribe tab and read out '
          'the address it shows.',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
