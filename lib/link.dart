// Live link between two phones over Wi-Fi.
//
// The sending phone runs a small TCP server; receivers connect to it. Messages
// are newline-delimited JSON, one object per line, so the stream is easy to
// read from anything - including a plain socket tool on a laptop.
//
// Only the original text travels. Each receiver translates for itself, so two
// people can listen to the same speaker in different languages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Port both ends use. Fixed so a receiver only needs the address.
const int linkPort = 45678;

/// Protocol version, sent in the greeting so a mismatch is obvious.
const int linkVersion = 1;

/// Message kinds on the wire.
class LinkMessage {
  const LinkMessage({
    required this.kind,
    this.text = '',
    this.lang = '',
    this.seq = 0,
  });

  /// One of: hello, partial, final, clear.
  final String kind;
  final String text;

  /// Language the text was spoken in, so the receiver knows what to translate
  /// from.
  final String lang;
  final int seq;

  Map<String, Object?> toJson() => {
        't': kind,
        if (text.isNotEmpty) 'text': text,
        if (lang.isNotEmpty) 'lang': lang,
        if (seq != 0) 'seq': seq,
      };

  static LinkMessage? parse(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final data = jsonDecode(line);
      if (data is! Map) return null;
      final kind = data['t'];
      if (kind is! String) return null;
      return LinkMessage(
        kind: kind,
        text: data['text'] as String? ?? '',
        lang: data['lang'] as String? ?? '',
        seq: (data['seq'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Serves the transcript to any number of receivers.
class LinkServer {
  ServerSocket? _server;
  final List<Socket> _clients = [];

  final StreamController<int> _clientCounts =
      StreamController<int>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  int _seq = 0;

  bool get running => _server != null;
  int get clientCount => _clients.length;

  /// Fires whenever a receiver connects or drops.
  Stream<int> get clientCounts => _clientCounts.stream;
  Stream<String> get errors => _errors.stream;

  /// Addresses a receiver can be pointed at. A phone usually has one Wi-Fi
  /// address; a hotspot adds another.
  Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ];
    } on SocketException {
      return const [];
    }
  }

  Future<bool> start({String lang = ''}) async {
    if (_server != null) return true;
    try {
      // anyIPv4 so both Wi-Fi and a USB forward can reach it.
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, linkPort);
      _server = server;
      server.listen(
        (socket) => _accept(socket, lang),
        onError: (Object error) => _errors.add('Link error: $error'),
      );
      return true;
    } on SocketException catch (error) {
      _errors.add(
        error.osError?.errorCode == 98 || error.osError?.errorCode == 10048
            ? 'Port $linkPort is already in use.'
            : 'Could not start the link: ${error.message}',
      );
      return false;
    }
  }

  void _accept(Socket socket, String lang) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _clients.add(socket);
    _clientCounts.add(_clients.length);
    // Greet so the receiver can show it is connected before anyone speaks.
    _writeTo(socket, LinkMessage(kind: 'hello', lang: lang));
    socket.listen(
      (_) {}, // Receivers never send anything; ignore whatever arrives.
      onDone: () => _drop(socket),
      onError: (Object _) => _drop(socket),
      cancelOnError: true,
    );
  }

  void _drop(Socket socket) {
    if (!_clients.remove(socket)) return;
    _clientCounts.add(_clients.length);
    try {
      socket.destroy();
    } catch (_) {
      // Already gone.
    }
  }

  void _writeTo(Socket socket, LinkMessage message) {
    try {
      socket.write('${jsonEncode(message.toJson())}\n');
    } catch (_) {
      _drop(socket);
    }
  }

  void _broadcast(LinkMessage message) {
    // Copy first: a failed write removes the socket from the live list.
    for (final socket in List<Socket>.from(_clients)) {
      _writeTo(socket, message);
    }
  }

  /// Words still being recognised. Sent as they change so the far end sees
  /// the sentence forming, not just the finished result.
  void sendPartial(String text, String lang) {
    if (_clients.isEmpty) return;
    _broadcast(LinkMessage(kind: 'partial', text: text, lang: lang));
  }

  void sendFinal(String text, String lang) {
    if (_clients.isEmpty) return;
    _broadcast(
      LinkMessage(kind: 'final', text: text, lang: lang, seq: ++_seq),
    );
  }

  void sendClear() {
    if (_clients.isEmpty) return;
    _broadcast(const LinkMessage(kind: 'clear'));
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final socket in List<Socket>.from(_clients)) {
      _drop(socket);
    }
    await server?.close();
  }

  Future<void> dispose() async {
    await stop();
    await _clientCounts.close();
    await _errors.close();
  }
}

/// How the receiving end is doing.
enum LinkState { idle, connecting, connected, failed }

/// Connects to a sending phone and reports what it says.
class LinkClient {
  Socket? _socket;
  StreamSubscription<String>? _lines;
  Timer? _retry;
  String? _host;
  bool _wanted = false;

  /// Grows each time a connection drops so a missing host does not spin.
  int _attempts = 0;

  final StreamController<LinkState> _states =
      StreamController<LinkState>.broadcast();
  final StreamController<LinkMessage> _messages =
      StreamController<LinkMessage>.broadcast();

  LinkState _state = LinkState.idle;
  String? _detail;

  LinkState get state => _state;
  String? get detail => _detail;
  String? get host => _host;

  Stream<LinkState> get states => _states.stream;
  Stream<LinkMessage> get messages => _messages.stream;

  void _setState(LinkState next, [String? detail]) {
    _state = next;
    _detail = detail;
    if (!_states.isClosed) _states.add(next);
  }

  /// Starts connecting and keeps trying until [disconnect] is called, so the
  /// receiver survives the sender being started afterwards.
  Future<void> connect(String host) async {
    _host = host.trim();
    _wanted = true;
    _attempts = 0;
    await _attempt();
  }

  Future<void> _attempt() async {
    if (!_wanted) return;
    final host = _host;
    if (host == null || host.isEmpty) {
      _setState(LinkState.failed, 'Enter the address shown on the other phone.');
      return;
    }
    await _closeSocket();
    _setState(LinkState.connecting, 'Connecting to $host…');
    try {
      final socket = await Socket.connect(
        host,
        linkPort,
        timeout: const Duration(seconds: 8),
      );
      if (!_wanted) {
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _attempts = 0;
      _setState(LinkState.connected, 'Connected to $host');
      _lines = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onDone: _onDropped,
            onError: (Object _) => _onDropped(),
            cancelOnError: true,
          );
    } on SocketException catch (error) {
      _setState(LinkState.failed, 'Could not connect: ${error.message}');
      _scheduleRetry();
    } on TimeoutException {
      _setState(LinkState.failed, 'No answer from $host.');
      _scheduleRetry();
    }
  }

  void _onLine(String line) {
    final message = LinkMessage.parse(line);
    if (message != null && !_messages.isClosed) _messages.add(message);
  }

  void _onDropped() {
    if (!_wanted) return;
    _setState(LinkState.failed, 'The other phone disconnected.');
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_wanted) return;
    _attempts++;
    final seconds = _attempts > 5 ? 10 : _attempts * 2;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), _attempt);
  }

  Future<void> _closeSocket() async {
    await _lines?.cancel();
    _lines = null;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }

  Future<void> disconnect() async {
    _wanted = false;
    _retry?.cancel();
    await _closeSocket();
    _setState(LinkState.idle);
  }

  Future<void> dispose() async {
    await disconnect();
    await _states.close();
    await _messages.close();
  }
}
