import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import 'data_dir.dart';
import 'outbox_service.dart';
import 'peer_crypto.dart';

/// This copy of Thread Suit, as other copies see it. Kept in `device.json`.
class Device {
  final String id;
  final String name;
  const Device(this.id, this.name);

  static Device load(DataDir dir) {
    try {
      final j = jsonDecode(File(dir.device).readAsStringSync()) as Map<String, dynamic>;
      return Device(j['id'] as String, (j['name'] as String?) ?? _hostName());
    } catch (_) {
      final r = Random.secure();
      final d = Device(List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join(), _hostName());
      File(dir.device).writeAsStringSync(jsonEncode({'id': d.id, 'name': d.name}));
      return d;
    }
  }

  static String _hostName() {
    final h = Platform.localHostname.split('.').first;
    return h.isEmpty ? 'Computer' : h;
  }
}

/// A computer this one is paired with. Kept in `peers.json`.
class PairedPeer {
  final String id;
  final String name;
  final Uri url;

  /// The traffic key the pairing made (see [PeerCrypto]).
  final List<int> key;

  const PairedPeer({required this.id, required this.name, required this.url, required this.key});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': '$url', 'key': base64Encode(key)};

  static PairedPeer? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['url'] is! String || j['key'] is! String) return null;
    final url = Uri.tryParse(j['url'] as String);
    if (url == null || !url.hasAuthority) return null;
    return PairedPeer(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? url.host,
      url: url,
      key: base64Decode(j['key'] as String),
    );
  }
}

/// What the list knows about one paired computer.
class PeerStatus {
  final PairedPeer peer;
  final List<ThreadSummary> threads;

  /// When it last answered; null if it hasn't yet.
  final DateTime? seenAt;

  /// Why the last read failed; null if it worked.
  final String? error;

  const PeerStatus(this.peer, {this.threads = const [], this.seenAt, this.error});
}

/// A copy of Thread Suit that answered on the local network.
class FoundComputer {
  final String id;
  final String name;
  final Uri url;
  const FoundComputer(this.id, this.name, this.url);
}

enum PairingStep { connecting, comparing, paired, rejected, failed }

/// Pairing this computer started, as its screen shows it.
class OutgoingPairing {
  final Uri url;
  final PairingStep step;
  final String? name;
  final String? code;
  final String? error;
  const OutgoingPairing(this.url, this.step, {this.name, this.code, this.error});
}

/// Another computer asking to pair with this one: show [code] and ask
/// whether it matches the code on [name]'s screen.
class IncomingPairing {
  final String id;
  final String name;
  final String code;
  const IncomingPairing(this.id, this.name, this.code);
}

/// Thrown when the other computer answered and said no, so trying again
/// won't help.
class PeerRefused implements Exception {
  final String message;
  const PeerRefused(this.message);
  @override
  String toString() => message;
}

/// Connects the copies of Thread Suit on your computers, with no AI, no
/// Claude login and no server in between.
///
/// **Pairing:** one computer finds the other on the network (or you type its
/// address) and asks to pair. Both screens show the same 6-digit code; you
/// check they match and click Yes on the computer that was asked. That one
/// click pairs both. See [PeerCrypto] for why the code can't be faked.
///
/// **Once paired**, each computer reads the other's threads every
/// [interval] and hands it your replies, which it queues for the thread's
/// own session in its outbox and delivers as usual. Everything between them
/// is encrypted with the key from pairing.
///
/// It listens on TCP [defaultPort] for the API and on the same UDP port to
/// be found. `{"peers": {"enabled": false}}` in `config.json` turns all of it
/// off; `"port"` there moves it.
class PeerService implements InjectableWithDisposeInterface {
  static const defaultPort = 47322;
  static const interval = Duration(seconds: 5);
  static const pairingTimeout = Duration(minutes: 2);
  static const _timeout = Duration(seconds: 8);
  static const maxBody = 256 * 1024;

  /// Sealed requests older than this are refused, so they can't be replayed later.
  static const maxAge = Duration(minutes: 2);
  static const _probe = 'thread-suit-hello/1';

  final DataDir _dir;
  final Device me;
  final int port;
  final Snapshot? Function() _local;
  final OutboxService _outbox;
  final HttpClient _client = HttpClient()..connectionTimeout = _timeout;

  final _status = BehaviorSubject<List<PeerStatus>>.seeded(const []);
  final _found = BehaviorSubject<List<FoundComputer>>.seeded(const []);
  final _outgoing = BehaviorSubject<OutgoingPairing?>.seeded(null);
  final _incoming = BehaviorSubject<IncomingPairing?>.seeded(null);

  HttpServer? _server;
  RawDatagramSocket? _udp;
  Timer? _timer;
  final _ready = Completer<void>();

  /// Why other computers can't reach this one, if they can't.
  String? listenError;

  Stream<List<PeerStatus>> get statusStream => _status.stream;
  List<PeerStatus> get status => _status.value;
  Stream<List<FoundComputer>> get foundStream => _found.stream;
  Stream<OutgoingPairing?> get outgoingStream => _outgoing.stream;
  Stream<IncomingPairing?> get incomingStream => _incoming.stream;
  OutgoingPairing? get outgoing => _outgoing.value;
  IncomingPairing? get incoming => _incoming.value;

  /// The TCP port the API listens on (differs from [port] when that is 0, in tests).
  int? get listeningPort => _server?.port;

  /// Completes once listening has started or failed.
  Future<void> get ready => _ready.future;

  PeerService(
    this._dir,
    this._local,
    this._outbox, {
    Device? device,
    int? port,
    bool? enabled,
    InternetAddress? address,
  }) : me = device ?? Device.load(_dir),
       port = port ?? _config(_dir)['port'] as int? ?? defaultPort {
    _status.add([for (final p in _loadPeers()) PeerStatus(p)]);
    if (enabled ?? _config(_dir)['enabled'] != false) {
      unawaited(_listen(address ?? InternetAddress.anyIPv4).whenComplete(_ready.complete));
    } else {
      listenError = 'Connecting computers is turned off in config.json';
      _ready.complete();
    }
    unawaited(pollNow());
    _timer = Timer.periodic(interval, (_) => pollNow());
  }

  static Map<String, dynamic> _config(DataDir dir) {
    try {
      final peers = (jsonDecode(File(dir.config).readAsStringSync()) as Map)['peers'];
      return peers is Map<String, dynamic> ? peers : const {};
    } catch (_) {
      return const {};
    }
  }

  List<PairedPeer> _loadPeers() {
    try {
      return [for (final j in jsonDecode(File(_dir.paired).readAsStringSync()) as List) ?PairedPeer.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  void _setPeers(List<PeerStatus> next) {
    final tmp = File('${_dir.paired}.tmp')
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert([for (final s in next) s.peer.toJson()]));
    tmp.renameSync(_dir.paired);
    if (!_status.isClosed) _status.add(next);
  }

  List<PairedPeer> get peers => [for (final s in status) s.peer];

  /// Adds or replaces [p] (pairing again with the same computer replaces it).
  void _addPeer(PairedPeer p) {
    _setPeers([
      for (final s in status)
        if (s.peer.id != p.id) s,
      PeerStatus(p),
    ]);
    unawaited(pollNow());
  }

  void _removePeer(String id) => _setPeers([
    for (final s in status)
      if (s.peer.id != id) s,
  ]);

  /// Unpairs [id] here, and tells it to unpair too if it can be reached.
  Future<void> forget(String id) async {
    final p = peers.where((p) => p.id == id).firstOrNull;
    if (p == null) return;
    _removePeer(id);
    try {
      await _sealedCall(p, '/v1/forget', {});
    } catch (_) {}
  }

  // ---------------------------------------------------------------- server

  Future<void> _listen(InternetAddress address) async {
    try {
      _server = await HttpServer.bind(address, port);
      _server!.listen((req) => _handle(req).catchError((_) {}));
    } catch (e) {
      listenError = "Other computers can't reach this one: port $port is busy";
      return;
    }
    try {
      _udp = await RawDatagramSocket.bind(address, _server!.port)
        ..broadcastEnabled = true;
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = _udp?.receive();
        if (d != null) _onDatagram(d);
      });
    } catch (_) {
      // Not findable on the network; typing the address still works.
    }
  }

  void _onDatagram(Datagram d) {
    final text = utf8.decode(d.data, allowMalformed: true);
    if (text == _probe) {
      final answer = jsonEncode({'t': 'thread-suit', 'id': me.id, 'name': me.name, 'port': _server?.port});
      _udp?.send(utf8.encode(answer), d.address, d.port);
      return;
    }
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j['t'] != 'thread-suit' || j['id'] == me.id || j['id'] is! String || j['port'] is! int) return;
      final found = FoundComputer(
        j['id'] as String,
        (j['name'] as String?) ?? d.address.address,
        Uri(scheme: 'http', host: d.address.address, port: j['port'] as int),
      );
      if (_found.isClosed) return;
      _found.add([
        for (final f in _found.value)
          if (f.id != found.id) f,
        found,
      ]);
    } catch (_) {}
  }

  /// Asks the local network who's there; answers arrive on [foundStream].
  /// [to] and [toPort] are for tests.
  void discover({InternetAddress? to, int? toPort}) {
    try {
      _udp?.send(utf8.encode(_probe), to ?? InternetAddress('255.255.255.255'), toPort ?? port);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    if (req.contentLength > maxBody) return null;
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > maxBody) return null;
    }
    try {
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _handle(HttpRequest req) async {
    Future<void> reply(int code, Object body) async {
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    }

    if (req.method != 'POST') return reply(HttpStatus.methodNotAllowed, {'error': 'POST only'});
    final body = await _readJson(req);
    if (body == null) return reply(HttpStatus.badRequest, {'error': 'Not JSON, or too long'});
    final path = req.uri.path;
    if (path.startsWith('/v1/pair/')) return _handlePairing(path, body, req, reply);

    // Everything else is sealed under a paired computer's key.
    final from = peers.where((p) => p.id == body['from']).firstOrNull;
    final sealed = body['sealed'];
    if (from == null || sealed is! String) return reply(HttpStatus.unauthorized, {'error': 'Not paired'});
    final msg = await PeerCrypto.open(from.key, sealed, _context(path, from.id, me.id));
    final ts = DateTime.tryParse('${msg?['ts']}');
    if (msg == null || ts == null || DateTime.now().difference(ts).abs() > maxAge) {
      return reply(HttpStatus.unauthorized, {'error': 'Not paired'});
    }
    if (!_firstTime(sealed)) return reply(HttpStatus.conflict, {'error': 'Already received'});

    Future<void> answer(Map<String, dynamic> m) async =>
        reply(HttpStatus.ok, {'sealed': await PeerCrypto.seal(from.key, m, _context('$path reply', me.id, from.id))});
    final local = _local()?.threads ?? const <ThreadSummary>[];
    switch (path) {
      case '/v1/threads':
        return answer({
          'threads': [for (final t in local) t.toJson()],
        });
      case '/v1/send':
        final text = msg['text'], id = msg['thread_id'];
        if (text is! String || text.trim().isEmpty || id is! String) {
          return answer({'error': 'Needs thread_id and text'});
        }
        // Only to a thread this computer has, and to its own session.
        final thread = local.where((t) => t.threadId == id).firstOrNull;
        if (thread?.sessionId == null) return answer({'error': 'No such thread on ${me.name}'});
        return answer({'queued': _outbox.queue(thread!.threadId, thread.sessionId!, text)});
      case '/v1/forget':
        _removePeer(from.id);
        return answer({'ok': true});
    }
    return answer({'error': 'Not found'});
  }

  /// What a sealed message is bound to, so it can't be replayed elsewhere.
  static String _context(String path, String from, String to) => 'thread-suit/1 $path $from->$to';

  final _seen = <String, DateTime>{};

  /// Whether [sealed] is new; each sealed request is accepted once.
  bool _firstTime(String sealed) {
    final now = DateTime.now();
    _seen.removeWhere((_, at) => now.difference(at) > maxAge * 2);
    return identical(_seen.putIfAbsent(sealed, () => now), now);
  }

  // ---- pairing, the asked side

  _Pending? _pending;

  Future<void> _handlePairing(
    String path,
    Map<String, dynamic> body,
    HttpRequest req,
    Future<void> Function(int, Object) reply,
  ) async {
    final p = _pending;
    final expired = p != null && DateTime.now().difference(p.at) > pairingTimeout;
    if (expired) _clearIncoming();
    switch (path) {
      case '/v1/pair/hello':
        final id = body['id'], name = body['name'], port = body['port'], commit = body['commit'];
        if (id is! String || name is! String || port is! int || commit is! String) {
          return reply(HttpStatus.badRequest, {'error': 'Bad hello'});
        }
        // One at a time, so nobody can flood the screen with requests.
        if (_pending != null) return reply(HttpStatus.conflict, {'error': '${me.name} is busy pairing'});
        final keys = await PeerCrypto.newKeyPair();
        _pending = _Pending(
          id: id,
          name: name.length > 60 ? name.substring(0, 60) : name,
          url: Uri(scheme: 'http', host: req.connectionInfo!.remoteAddress.address, port: port),
          commit: commit,
          keys: keys,
          at: DateTime.now(),
        );
        return reply(HttpStatus.ok, {
          'id': me.id,
          'name': me.name,
          'pub': base64Encode(await PeerCrypto.publicKey(keys)),
        });
      case '/v1/pair/reveal':
        final pub = body['pub'];
        if (p == null || expired || body['id'] != p.id || pub is! String || p.agreed != null) {
          return reply(HttpStatus.notFound, {'error': 'No pairing in progress'});
        }
        final theirs = base64Decode(pub);
        if (!await PeerCrypto.checkCommit(p.commit, theirs)) {
          _clearIncoming();
          return reply(HttpStatus.forbidden, {'error': "The key doesn't match what was promised"});
        }
        final mine = await PeerCrypto.publicKey(p.keys);
        p.agreed = await PeerCrypto.agree(p.keys, theirs, startPub: theirs, answerPub: mine);
        _incoming.add(IncomingPairing(p.id, p.name, p.agreed!.code));
        return reply(HttpStatus.ok, {'ok': true});
      case '/v1/pair/status':
        if (p == null || expired || body['id'] != p.id) return reply(HttpStatus.ok, {'state': 'gone'});
        final answer = p.answer;
        if (answer == null) return reply(HttpStatus.ok, {'state': 'waiting'});
        final proof = answer
            ? await PeerCrypto.seal(p.agreed!.key, {'accepted': true}, _context('pair', me.id, p.id))
            : null;
        _pending = null;
        return reply(HttpStatus.ok, {'state': answer ? 'accepted' : 'rejected', 'proof': ?proof});
      case '/v1/pair/cancel':
        if (p != null && body['id'] == p.id) _clearIncoming();
        return reply(HttpStatus.ok, {'ok': true});
    }
    return reply(HttpStatus.notFound, {'error': 'Not found'});
  }

  void _clearIncoming() {
    _pending = null;
    if (!_incoming.isClosed) _incoming.add(null);
  }

  /// Your answer to [incoming]: Yes pairs both computers.
  void answerIncoming(bool yes) {
    final p = _pending;
    if (p == null || p.agreed == null || p.answer != null) return;
    p.answer = yes;
    if (yes) _addPeer(PairedPeer(id: p.id, name: p.name, url: p.url, key: p.agreed!.key));
    _incoming.add(null);
    // The other computer collects the answer; drop the request if it never does.
    Timer(const Duration(seconds: 30), () {
      if (identical(_pending, p)) _pending = null;
    });
  }

  // ---------------------------------------------------------------- client

  Future<Map<String, dynamic>> _post(Uri base, String path, Map<String, dynamic> body) async {
    final req = await _client.postUrl(base.resolve(path)).timeout(_timeout);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close().timeout(_timeout);
    final text = await res.transform(utf8.decoder).join().timeout(_timeout);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw const HttpException('Not a Thread Suit answer');
    }
    if (res.statusCode >= 400) {
      final why = '${json['error'] ?? 'HTTP ${res.statusCode}'}';
      if (res.statusCode < 500) throw PeerRefused(why);
      throw HttpException(why);
    }
    return json;
  }

  /// A sealed request to [p], and its sealed answer.
  Future<Map<String, dynamic>> _sealedCall(PairedPeer p, String path, Map<String, dynamic> msg) async {
    final sealed = await PeerCrypto.seal(p.key, {
      ...msg,
      'ts': DateTime.now().toUtc().toIso8601String(),
    }, _context(path, me.id, p.id));
    final res = await _post(p.url, path, {'from': me.id, 'sealed': sealed});
    final answer = res['sealed'] is String
        ? await PeerCrypto.open(p.key, res['sealed'] as String, _context('$path reply', p.id, me.id))
        : null;
    if (answer == null) throw const PeerRefused('The answer was not from the paired computer');
    if (answer['error'] is String) throw PeerRefused(answer['error'] as String);
    return answer;
  }

  Future<void>? _polling;

  /// Reads every paired computer once. While a read is running, returns
  /// that one instead of starting another.
  @visibleForTesting
  Future<void> pollNow() =>
      _polling ??= Future.wait([for (final p in peers) _poll(p)]).whenComplete(() => _polling = null);

  Future<void> _poll(PairedPeer p) async {
    PeerStatus next;
    final before = status.where((s) => s.peer.id == p.id).firstOrNull;
    try {
      final json = await _sealedCall(p, '/v1/threads', {});
      next = PeerStatus(
        p,
        threads: [
          for (final t in (json['threads'] as List? ?? const []))
            if (t is Map<String, dynamic>) ThreadSummary.fromJson(t).onMachine(p.name, p.id),
        ],
        seenAt: DateTime.now(),
      );
    } catch (e) {
      // Keep showing what it last said; say why it's stale.
      next = PeerStatus(p, threads: before?.threads ?? const [], seenAt: before?.seenAt, error: _short(e));
    }
    if (_status.isClosed || !peers.any((x) => x.id == p.id)) return;
    _status.add([for (final s in status) s.peer.id == p.id ? next : s]);
  }

  static String _short(Object e) => switch (e) {
    PeerRefused(:final message) => message,
    HttpException(:final message) => message,
    SocketException(:final osError, :final message) => osError?.message ?? message,
    TimeoutException() => 'No answer',
    _ => '$e',
  };

  /// Hands [m] (a reply to a thread on another computer) to that computer,
  /// which queues it for the thread's session. Throws [PeerRefused] if it
  /// said no, or another error if it couldn't be reached (worth retrying).
  Future<void> send(OutboxMessage m) async {
    final p = peers.where((p) => p.id == m.machine).firstOrNull;
    if (p == null) throw const PeerRefused('That computer is no longer paired');
    final prefix = '${p.id}:';
    if (!m.threadId.startsWith(prefix)) throw PeerRefused('Not a thread on ${p.name}');
    await _sealedCall(p, '/v1/send', {'thread_id': m.threadId.substring(prefix.length), 'text': m.text});
  }

  /// The paired computer [id]'s name, for messages about it.
  String nameOf(String id) => peers.where((p) => p.id == id).firstOrNull?.name ?? 'the other computer';

  // ---- pairing, the asking side

  int _attempt = 0;

  /// Asks the computer at [url] to pair. Both screens then show a code;
  /// clicking Yes on that computer pairs both. Progress is on [outgoingStream].
  Future<void> pairWith(Uri url) async {
    final attempt = ++_attempt;
    bool current() => attempt == _attempt && !_outgoing.isClosed;
    _outgoing.add(OutgoingPairing(url, PairingStep.connecting));
    String? theirName;
    try {
      final SimpleKeyPair keys = await PeerCrypto.newKeyPair();
      final mine = await PeerCrypto.publicKey(keys);
      final hello = await _post(url, '/v1/pair/hello', {
        'id': me.id,
        'name': me.name,
        'port': listeningPort ?? port,
        'commit': await PeerCrypto.commit(mine),
      });
      final theirId = hello['id'] as String;
      if (theirId == me.id) throw const PeerRefused("That's this computer");
      theirName = hello['name'] as String;
      final theirs = base64Decode(hello['pub'] as String);
      await _post(url, '/v1/pair/reveal', {'id': me.id, 'pub': base64Encode(mine)});
      final agreed = await PeerCrypto.agree(keys, theirs, startPub: mine, answerPub: theirs);
      if (!current()) return;
      _outgoing.add(OutgoingPairing(url, PairingStep.comparing, name: theirName, code: agreed.code));

      final until = DateTime.now().add(pairingTimeout);
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!current()) return;
        final s = await _post(url, '/v1/pair/status', {'id': me.id});
        switch (s['state']) {
          case 'waiting':
            continue;
          case 'accepted':
            final proof = s['proof'] is String
                ? await PeerCrypto.open(agreed.key, s['proof'] as String, _context('pair', theirId, me.id))
                : null;
            if (proof?['accepted'] != true) throw const PeerRefused('The answer was not from that computer');
            _addPeer(PairedPeer(id: theirId, name: theirName, url: url, key: agreed.key));
            if (current()) _outgoing.add(OutgoingPairing(url, PairingStep.paired, name: theirName, code: agreed.code));
            return;
          case 'rejected':
            _outgoing.add(OutgoingPairing(url, PairingStep.rejected, name: theirName, code: agreed.code));
            return;
          default:
            throw const PeerRefused('The other computer stopped pairing');
        }
      }
      throw const PeerRefused('Nobody answered in time');
    } catch (e) {
      if (!current()) return;
      _outgoing.add(OutgoingPairing(url, PairingStep.failed, name: theirName, error: _short(e)));
    }
  }

  /// Stops or dismisses pairing this computer started, and tells the other
  /// one if it was still going.
  void cancelPairing() {
    final o = _outgoing.value;
    _attempt++;
    _outgoing.add(null);
    if (o != null && (o.step == PairingStep.connecting || o.step == PairingStep.comparing)) {
      unawaited(_post(o.url, '/v1/pair/cancel', {'id': me.id}).then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _attempt++;
    _client.close(force: true);
    _udp?.close();
    await _server?.close(force: true);
    await _status.close();
    await _found.close();
    await _outgoing.close();
    await _incoming.close();
  }
}

class _Pending {
  final String id;
  final String name;
  final Uri url;
  final String commit;
  final SimpleKeyPair keys;
  final DateTime at;
  ({String code, List<int> key})? agreed;
  bool? answer;

  _Pending({
    required this.id,
    required this.name,
    required this.url,
    required this.commit,
    required this.keys,
    required this.at,
  });
}
