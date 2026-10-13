// Live link between two phones over Wi-Fi.
//
// One phone hosts a small TCP server; the others join it. Messages are
// newline-delimited JSON, one object per line, so the stream is easy to read
// from anything - including a plain socket tool on a laptop.
//
// The link runs both ways: everyone joined can speak and everyone hears
// everyone else. The host relays each guest's words to the other guests, so a
// three-way conversation works without anyone connecting twice.
//
// Only the original text travels, tagged with the language it was spoken in.
// Each phone translates what arrives into its own language, so two people can
// follow the same conversation in different languages.

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
    this.from = '',
  });

  /// One of: hello, partial, final, clear.
  final String kind;
  final String text;

  /// Language the text was spoken in, so whoever receives it knows what to
  /// translate from.
  final String lang;
  final int seq;

  /// Who said it, so a phone can tell the host apart from the other guests
  /// and label the conversation. Empty on a message a phone sends about
  /// itself; filled in by the host when it relays.
  final String from;

  Map<String, Object?> toJson() => {
        't': kind,
        if (text.isNotEmpty) 'text': text,
        if (lang.isNotEmpty) 'lang': lang,
        if (seq != 0) 'seq': seq,
        if (from.isNotEmpty) 'from': from,
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
        from: data['from'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Hosts the conversation: serves what this phone hears to everyone joined,
/// and passes on what they say in return.
class LinkServer {
  ServerSocket? _server;
  final List<Socket> _clients = [];

  /// Name shown for each guest, so lines arriving from two different phones
  /// are not run together. Kept per socket and dropped when it disconnects.
  final Map<Socket, String> _names = {};

  /// Guests numbered in the order they first joined. Never reused, so a guest
  /// that drops and returns does not take over the earlier one's lines.
  int _joined = 0;

  final StreamController<int> _clientCounts =
      StreamController<int>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final StreamController<LinkMessage> _inbound =
      StreamController<LinkMessage>.broadcast();

  int _seq = 0;

  /// Language this phone is speaking, sent in the greeting so a guest knows
  /// what to translate from before anyone says anything. Kept here rather
  /// than captured at start-up so a later language change still reaches
  /// whoever joins next.
  String _lang = '';

  bool get running => _server != null;
  int get clientCount => _clients.length;

  /// Fires whenever a guest connects or drops.
  Stream<int> get clientCounts => _clientCounts.stream;
  Stream<String> get errors => _errors.stream;

  /// What the guests say, tagged with who said it.
  Stream<LinkMessage> get inbound => _inbound.stream;

  /// Addresses a guest can be pointed at, best first.
  ///
  /// A phone with mobile data has an address on that interface too, and
  /// another phone cannot route to it. Showing that one first sends people to
  /// an address that times out, so Wi-Fi and hotspot interfaces come first and
  /// mobile ones are dropped entirely.
  Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      int rank(String name) {
        final lower = name.toLowerCase();
        if (lower.startsWith('wlan')) return 0; // Joined a Wi-Fi network.
        if (lower.startsWith('ap') || lower.startsWith('swlan')) {
          return 1; // This phone is the hotspot.
        }
        return 2;
      }

      // rmnet/ccmni are the mobile data interfaces; unreachable from another
      // phone, so they are not offered at all.
      bool isMobile(String name) {
        final lower = name.toLowerCase();
        return lower.startsWith('rmnet') ||
            lower.startsWith('ccmni') ||
            lower.startsWith('pdp') ||
            lower.startsWith('clat');
      }

      final usable = interfaces.where((i) => !isMobile(i.name)).toList()
        ..sort((a, b) => rank(a.name).compareTo(rank(b.name)));

      return [
        for (final interface in usable)
          for (final address in interface.addresses) address.address,
      ];
    } on SocketException {
      return const [];
    }
  }

  /// Tells the host's guests which language it has switched to.
  void setLanguage(String lang) {
    if (lang == _lang) return;
    _lang = lang;
    if (_clients.isNotEmpty) _broadcast(LinkMessage(kind: 'hello', lang: lang));
  }

  Future<bool> start({String lang = ''}) async {
    if (_server != null) return true;
    _lang = lang;
    try {
      // anyIPv4 so both Wi-Fi and a USB forward can reach it.
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, linkPort);
      _server = server;
      server.listen(
        _accept,
        onError: (Object error) => _report('Link error: $error'),
      );
      return true;
    } on SocketException catch (error) {
      _report(
        error.osError?.errorCode == 98 || error.osError?.errorCode == 10048
            ? 'Port $linkPort is already in use.'
            : 'Could not start the link: ${error.message}',
      );
      return false;
    }
  }

  void _accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _clients.add(socket);
    _names[socket] = 'Guest ${++_joined}';
    _notifyCount();
    // Greet so the guest can show it is connected before anyone speaks.
    _writeTo(socket, LinkMessage(kind: 'hello', lang: _lang));
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _onLine(socket, line),
          onDone: () => _drop(socket),
          onError: (Object _) => _drop(socket),
          cancelOnError: true,
        );
  }

  /// A guest spoke. Report it to this phone and pass it on to the other
  /// guests, so everyone joined hears everyone else rather than only the host.
  void _onLine(Socket socket, String line) {
    final message = LinkMessage.parse(line);
    if (message == null) return;
    final stamped = LinkMessage(
      kind: message.kind,
      text: message.text,
      lang: message.lang,
      seq: message.seq,
      // Trust the host's own naming over whatever the guest claims to be.
      from: _names[socket] ?? 'Guest',
    );
    if (!_inbound.isClosed) _inbound.add(stamped);
    for (final other in List<Socket>.from(_clients)) {
      if (other != socket) _writeTo(other, stamped);
    }
  }

  void _drop(Socket socket) {
    _names.remove(socket);
    if (!_clients.remove(socket)) return;
    _notifyCount();
    try {
      socket.destroy();
    } catch (_) {
      // Already gone.
    }
  }

  void _notifyCount() {
    if (!_clientCounts.isClosed) _clientCounts.add(_clients.length);
  }

  void _report(String message) {
    if (!_errors.isClosed) _errors.add(message);
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
    await _inbound.close();
  }
}

/// How the receiving end is doing.
enum LinkState { idle, connecting, connected, failed }

/// Joins a hosted conversation: reports what the others say, and sends back
/// what this phone hears.
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

  int _seq = 0;

  /// Language this phone is speaking. Sent as a greeting the moment a
  /// connection comes up, so the host knows what to translate from before
  /// anything is said - and again after a reconnect, which the retry loop
  /// does on its own.
  String _lang = '';

  /// True while there is a live socket to speak into.
  bool get connected => _state == LinkState.connected && _socket != null;

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
  Future<void> connect(String host, {String lang = ''}) async {
    _host = host.trim();
    _wanted = true;
    _attempts = 0;
    if (lang.isNotEmpty) _lang = lang;
    await _attempt();
  }

  /// Tells the host which language this phone has switched to.
  void setLanguage(String lang) {
    if (lang == _lang) return;
    _lang = lang;
    if (connected) _send(LinkMessage(kind: 'hello', lang: lang));
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
      // Greet first so the host can prepare translation for this phone's
      // language before the first sentence arrives.
      if (_lang.isNotEmpty) _send(LinkMessage(kind: 'hello', lang: _lang));
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

  void _send(LinkMessage message) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.write('${jsonEncode(message.toJson())}\n');
    } catch (_) {
      // The socket is gone; the retry loop will notice and reconnect.
    }
  }

  /// Words still being recognised on this phone, so the far end sees the
  /// sentence forming instead of waiting for the whole thing.
  void sendPartial(String text, String lang) {
    if (!connected) return;
    _send(LinkMessage(kind: 'partial', text: text, lang: lang));
  }

  void sendFinal(String text, String lang) {
    if (!connected) return;
    _send(LinkMessage(kind: 'final', text: text, lang: lang, seq: ++_seq));
  }

  void sendClear() {
    if (!connected) return;
    _send(const LinkMessage(kind: 'clear'));
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
