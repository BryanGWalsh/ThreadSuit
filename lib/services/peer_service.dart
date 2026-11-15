import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import 'data_dir.dart';
import 'outbox_service.dart';

/// How this copy of Thread Suit shares its threads with your other copies,
/// from `share` in `config.json`:
///
/// ```json
/// {"share": {"port": 47322, "address": "100.64.0.5", "token": "..."}}
/// ```
///
/// Sharing is off without a `share` entry. `address` is the network address
/// to listen on (default: every address this computer has). `token` is the
/// pairing code other copies must send; one is made and saved the first time.
class ShareConfig {
  static const defaultPort = 47322;

  /// Shorter tokens are refused, so a guessable one can't be set by mistake.
  static const minTokenLength = 32;

  final int port;
  final String? address;
  final String token;

  const ShareConfig({this.port = defaultPort, this.address, required this.token});

  /// Reads `share` from [dir]'s config, making and saving a token if it has
  /// none. Null when sharing is off.
  static ShareConfig? read(DataDir dir) {
    Map<String, dynamic> config;
    try {
      config = jsonDecode(File(dir.config).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final share = config['share'];
    if (share is! Map) return null;
    var token = share['token'];
    if (token is! String || token.length < minTokenLength) {
      token = newToken();
      share['token'] = token;
      // Only this one key changes; everything else in the file is kept.
      final tmp = File('${dir.config}.tmp')..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
      tmp.renameSync(dir.config);
    }
    return ShareConfig(
      port: share['port'] is int ? share['port'] as int : defaultPort,
      address: share['address'] is String ? share['address'] as String : null,
      token: token,
    );
  }

  static String newToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Another computer's copy of Thread Suit, from `peers` in `config.json`:
///
/// ```json
/// {"peers": [{"name": "Laptop", "url": "http://100.64.0.7:47322", "token": "..."}]}
/// ```
///
/// `token` is the one in that computer's `share` entry.
class PeerConfig {
  final String name;
  final Uri url;
  final String token;

  const PeerConfig({required this.name, required this.url, required this.token});

  static List<PeerConfig> parse(Object? raw) {
    if (raw is! List) return const [];
    final out = <PeerConfig>[];
    for (final m in raw) {
      if (m is! Map || m['url'] is! String || m['token'] is! String) continue;
      final url = Uri.tryParse((m['url'] as String).trim());
      if (url == null || !url.hasAuthority || !{'http', 'https'}.contains(url.scheme)) continue;
      final name = m['name'] is String && (m['name'] as String).trim().isNotEmpty
          ? (m['name'] as String).trim()
          : url.host;
      // A ":" would make thread ids ambiguous ("<name>:<id>").
      out.add(PeerConfig(name: name.replaceAll(':', ' '), url: url, token: m['token'] as String));
    }
    return out;
  }

  static List<PeerConfig> read(DataDir dir) {
    try {
      return parse((jsonDecode(File(dir.config).readAsStringSync()) as Map)['peers']);
    } catch (_) {
      return const [];
    }
  }
}

/// What the list knows about one peer.
class PeerStatus {
  final PeerConfig config;
  final List<ThreadSummary> threads;

  /// When the peer last answered; null if it hasn't yet.
  final DateTime? seenAt;

  /// Why the last read failed; null if it worked.
  final String? error;

  const PeerStatus(this.config, {this.threads = const [], this.seenAt, this.error});
}

/// Thrown by [PeerService.send] when the peer answered and said no, so
/// trying again won't help.
class PeerRefused implements Exception {
  final String message;
  const PeerRefused(this.message);
  @override
  String toString() => message;
}

/// Connects the copies of Thread Suit on your computers to each other, with
/// no AI and no Claude login:
///
/// - **Sharing** ([ShareConfig]): serves this computer's threads (never ones
///   read from peers) to copies that send the token, and queues the replies
///   they send in this computer's outbox, which delivers them as usual.
/// - **Peers** ([PeerConfig]): reads each peer's threads every [interval],
///   and hands it replies to its threads.
///
/// The API, all behind `Authorization: Bearer <token>`:
/// `GET /v1/threads` and `POST /v1/send` with `{"thread_id", "text"}`.
class PeerService implements InjectableWithDisposeInterface {
  static const interval = Duration(seconds: 5);
  static const _timeout = Duration(seconds: 8);
  static const maxBody = 64 * 1024;

  /// This computer's threads now (normally `LocalThreadsService.current`).
  final Snapshot? Function() _local;
  final OutboxService _outbox;
  final ShareConfig? share;
  final List<PeerConfig> peers;
  final HttpClient _client = HttpClient()..connectionTimeout = _timeout;
  final _status = BehaviorSubject<List<PeerStatus>>.seeded(const []);
  HttpServer? _server;
  Timer? _timer;
  Future<void>? _polling;

  /// Why sharing couldn't start (port taken, bad address), if it couldn't.
  String? shareError;

  Stream<List<PeerStatus>> get statusStream => _status.stream;
  List<PeerStatus> get status => _status.value;

  PeerService(DataDir dir, this._local, this._outbox, {ShareConfig? share, List<PeerConfig>? peers, bool read = true})
    : share = share ?? (read ? ShareConfig.read(dir) : null),
      peers = peers ?? (read ? PeerConfig.read(dir) : const []) {
    if (this.share != null) unawaited(_serve(this.share!));
    if (this.peers.isNotEmpty) {
      _status.add([for (final p in this.peers) PeerStatus(p)]);
      unawaited(pollNow());
      _timer = Timer.periodic(interval, (_) => pollNow());
    }
  }

  /// The port sharing listens on, once it does (for tests using port 0).
  int? get sharePort => _server?.port;

  // ---- Sharing ----

  Future<void> _serve(ShareConfig c) async {
    try {
      final address = c.address == null ? InternetAddress.anyIPv4 : InternetAddress(c.address!);
      _server = await HttpServer.bind(address, c.port);
      _server!.listen((req) => _handle(req, c).catchError((_) {}));
    } catch (e) {
      shareError = 'Could not share on port ${c.port}: $e';
    }
  }

  /// Compares in constant time, so the token can't be guessed byte by byte.
  static bool _same(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < min(x.length, y.length); i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest req, ShareConfig c) async {
    final res = req.response;
    Future<void> reply(int code, Object body) async {
      res
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await res.close();
    }

    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!auth.startsWith('Bearer ') || !_same(auth.substring(7), c.token)) {
      return reply(HttpStatus.unauthorized, {'error': 'Wrong or missing token'});
    }
    final local = [
      for (final t in _local()?.threads ?? const <ThreadSummary>[])
        if (t.machine == null) t,
    ];
    if (req.method == 'GET' && req.uri.path == '/v1/threads') {
      return reply(HttpStatus.ok, {
        'threads': [for (final t in local) t.toJson()],
      });
    }
    if (req.method == 'POST' && req.uri.path == '/v1/send') {
      if ((req.contentLength) > maxBody) return reply(HttpStatus.requestEntityTooLarge, {'error': 'Too long'});
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
        if (bytes.length > maxBody) return reply(HttpStatus.requestEntityTooLarge, {'error': 'Too long'});
      }
      Map<String, dynamic> body;
      try {
        body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } catch (_) {
        return reply(HttpStatus.badRequest, {'error': 'Not JSON'});
      }
      final text = body['text'], id = body['thread_id'];
      if (text is! String || text.trim().isEmpty || id is! String) {
        return reply(HttpStatus.badRequest, {'error': 'Needs thread_id and text'});
      }
      // Only to a thread this computer has, and to its own session: the
      // sender can't pick an arbitrary session.
      final thread = local.where((t) => t.threadId == id).firstOrNull;
      if (thread == null || thread.sessionId == null) {
        return reply(HttpStatus.notFound, {'error': 'No such thread on this computer'});
      }
      final queued = _outbox.queue(thread.threadId, thread.sessionId!, text);
      return reply(HttpStatus.accepted, {'queued': queued});
    }
    return reply(HttpStatus.notFound, {'error': 'Not found'});
  }

  // ---- Peers ----

  Future<(int, Map<String, dynamic>)> _call(PeerConfig p, String method, String path, [Object? body]) async {
    final req = await _client.openUrl(method, p.url.resolve(path)).timeout(_timeout);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${p.token}');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(_timeout);
    final text = await res.transform(utf8.decoder).join().timeout(_timeout);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      json = {'error': 'Not a Thread Suit answer (HTTP ${res.statusCode})'};
    }
    return (res.statusCode, json);
  }

  /// Reads every peer once. While a read is running, returns that one
  /// instead of starting another.
  @visibleForTesting
  Future<void> pollNow() =>
      _polling ??= Future.wait([for (var i = 0; i < peers.length; i++) _poll(i)]).whenComplete(() => _polling = null);

  Future<void> _poll(int i) async {
    final p = peers[i];
    final before = status[i];
    PeerStatus next;
    try {
      final (code, json) = await _call(p, 'GET', '/v1/threads');
      if (code != HttpStatus.ok) throw HttpException('${json['error'] ?? 'HTTP $code'}');
      final threads = [
        for (final t in (json['threads'] as List? ?? const []))
          if (t is Map<String, dynamic>) ThreadSummary.fromJson(t).onMachine(p.name),
      ];
      next = PeerStatus(p, threads: threads, seenAt: DateTime.now());
    } catch (e) {
      // Keep showing what it last said; say why it's stale.
      next = PeerStatus(p, threads: before.threads, seenAt: before.seenAt, error: _short(e));
    }
    if (_status.isClosed) return;
    final all = [...status]..[i] = next;
    _status.add(all);
  }

  static String _short(Object e) => switch (e) {
    HttpException(:final message) => message,
    SocketException(:final osError, :final message) => osError?.message ?? message,
    TimeoutException() => 'No answer',
    _ => '$e',
  };

  /// Hands [m] (a reply to a thread on peer [m.machine]) to that peer, which
  /// queues it for its session. Returns when the peer has it. Throws
  /// [PeerRefused] if the peer said no, or another error if it couldn't be
  /// reached (worth trying again).
  Future<void> send(OutboxMessage m) async {
    final p = peers.where((p) => p.name == m.machine).firstOrNull;
    if (p == null) throw PeerRefused('${m.machine} is no longer in config.json');
    final prefix = '${p.name}:';
    if (!m.threadId.startsWith(prefix)) throw PeerRefused('Not a thread on ${p.name}');
    final (code, json) = await _call(p, 'POST', '/v1/send', {
      'thread_id': m.threadId.substring(prefix.length),
      'text': m.text,
    });
    if (code == HttpStatus.accepted) return;
    final why = '${json['error'] ?? 'HTTP $code'}';
    // A wrong token or unknown thread won't fix itself; a server error might.
    if (code >= 400 && code < 500) throw PeerRefused(why);
    throw HttpException(why);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _client.close(force: true);
    await _server?.close(force: true);
    await _status.close();
  }
}
