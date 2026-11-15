import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/models/models.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/outbox_service.dart';
import 'package:thread_suit/services/peer_crypto.dart';
import 'package:thread_suit/services/peer_service.dart';
import 'package:thread_suit/services/send_service.dart';
import 'package:thread_suit/ui/computers.dart';
import 'package:thread_suit/ui/format.dart';

class _NoCli extends ClaudeCli {
  int calls = 0;
  @override
  Future<String?> sendToSession(String sessionName, String text) async {
    calls++;
    return null;
  }
}

ThreadSummary _thread(String id) => ThreadSummary(
  threadId: id,
  sessionId: 'local_$id',
  title: 'Fix the $id',
  state: ThreadState.unknown,
  lastActivityAt: DateTime.utc(2026, 11, 15, 10),
  resolved: false,
  project: 'Shop',
  messagesAsOf: DateTime.utc(2026, 11, 15, 10),
  messages: [
    ThreadMessage(id: 'm1', author: 'You', fromHuman: true, sentAt: DateTime.utc(2026, 11, 15, 9), text: 'go'),
    ThreadMessage(
      id: 'm2',
      author: 'Claude',
      fromHuman: false,
      sentAt: DateTime.utc(2026, 11, 15, 10),
      text: 'done',
      isNotes: true,
    ),
  ],
);

/// One computer: its data folder, outbox and peer service, on 127.0.0.1.
class _Computer {
  final DataDir dir;
  final OutboxService outbox;
  final PeerService peers;
  _Computer(this.dir, this.outbox, this.peers);

  Uri get url => Uri.parse('http://127.0.0.1:${peers.listeningPort}');

  static Future<_Computer> start(Directory root, String name, {List<ThreadSummary> threads = const []}) async {
    final dir = DataDir.at('${root.path}/$name');
    final outbox = OutboxService(dir);
    final peers = PeerService(
      dir,
      () => Snapshot(generatedAt: DateTime.now(), projectName: '', threads: threads),
      outbox,
      device: Device('id-$name', name),
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    await peers.ready;
    addTearDown(() async {
      await peers.dispose();
      await outbox.dispose();
    });
    return _Computer(dir, outbox, peers);
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('peer'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('crypto', () {
    test('both sides get the same code and key; a different key gets a different code', () async {
      final a = await PeerCrypto.newKeyPair(), b = await PeerCrypto.newKeyPair(), m = await PeerCrypto.newKeyPair();
      final pa = await PeerCrypto.publicKey(a), pb = await PeerCrypto.publicKey(b), pm = await PeerCrypto.publicKey(m);
      final onA = await PeerCrypto.agree(a, pb, startPub: pa, answerPub: pb);
      final onB = await PeerCrypto.agree(b, pa, startPub: pa, answerPub: pb);
      expect(onA.code, onB.code);
      expect(onA.code, matches(RegExp(r'^\d{6}$')));
      expect(onA.key, onB.key);
      expect(onA.key, hasLength(32));
      // Someone in the middle has a different key with each side.
      final middle = await PeerCrypto.agree(a, pm, startPub: pa, answerPub: pm);
      expect(middle.key, isNot(onA.key));
      expect(PeerCrypto.spaced('123456'), '123 456');

      expect(await PeerCrypto.checkCommit(await PeerCrypto.commit(pa), pa), isTrue);
      expect(await PeerCrypto.checkCommit(await PeerCrypto.commit(pa), pm), isFalse);
    });

    test('a sealed message opens only with its key and for its purpose', () async {
      final key = List.generate(32, (i) => i), other = List.generate(32, (i) => 31 - i);
      final sealed = await PeerCrypto.seal(key, {'text': 'hi'}, 'send a->b');
      expect(sealed, isNot(contains('hi')));
      expect(await PeerCrypto.open(key, sealed, 'send a->b'), {'text': 'hi'});
      expect(await PeerCrypto.open(other, sealed, 'send a->b'), isNull);
      expect(await PeerCrypto.open(key, sealed, 'send b->a'), isNull);
      expect(await PeerCrypto.open(key, 'not base64!', 'send a->b'), isNull);
    });
  });

  test('a thread survives the trip and is tagged with its computer', () {
    final back = ThreadSummary.fromJson(jsonDecode(jsonEncode(_thread('login').toJson())) as Map<String, dynamic>);
    final t = back.onMachine('Desktop', 'id-desk');
    expect(t.threadId, 'id-desk:login');
    expect((t.machine, t.machineId, t.sessionId, t.title), ('Desktop', 'id-desk', 'local_login', 'Fix the login'));
    expect(t.messages.map((m) => (m.text, m.fromHuman, m.isNotes)), [('go', true, false), ('done', false, true)]);
    expect(origin(t), 'Project: Shop · on Desktop');
    expect(origin(_thread('x')), 'Project: Shop');
  });

  test('typed addresses get the default port', () {
    expect(ComputersDialogTestHooks.parse('192.168.1.20'), Uri.parse('http://192.168.1.20:47322'));
    expect(ComputersDialogTestHooks.parse(' desk.ts.net:5000 '), Uri.parse('http://desk.ts.net:5000'));
    expect(ComputersDialogTestHooks.parse(''), isNull);
  });

  test(
    'pairing: both show the same code, Yes on the asked computer pairs both, then threads and replies flow',
    () async {
      final desk = await _Computer.start(tmp, 'Desktop', threads: [_thread('login')]);
      final lap = await _Computer.start(tmp, 'Laptop');

      // The laptop finds the desktop on the "network".
      lap.peers.discover(to: InternetAddress.loopbackIPv4, toPort: desk.peers.listeningPort);
      final found = await lap.peers.foundStream.firstWhere((f) => f.isNotEmpty);
      expect(found.single.name, 'Desktop');
      expect(found.single.url, desk.url);

      final pairing = lap.peers.pairWith(found.single.url);
      final asked = await desk.peers.incomingStream.firstWhere((p) => p != null);
      final shown = await lap.peers.outgoingStream.firstWhere((o) => o?.step == PairingStep.comparing);
      expect(asked!.name, 'Laptop');
      expect(asked.code, shown!.code);

      desk.peers.answerIncoming(true);
      await pairing;
      expect(lap.peers.outgoing!.step, PairingStep.paired);
      expect(lap.peers.peers.single.name, 'Desktop');
      expect(desk.peers.peers.single.name, 'Laptop');
      expect(desk.peers.peers.single.url, lap.url);
      expect(lap.peers.peers.single.key, desk.peers.peers.single.key);
      // Saved, and nothing is in plain text but the key itself.
      expect(File(lap.dir.paired).readAsStringSync(), contains('id-Desktop'));

      await lap.peers.pollNow();
      final seen = lap.peers.status.single;
      expect(seen.error, isNull);
      expect(seen.threads.single.threadId, 'id-Desktop:login');
      expect(seen.threads.single.machine, 'Desktop');

      // A reply typed on the laptop is queued on the desktop for that thread's session.
      final cli = _NoCli();
      final sender = SendService(lap.outbox, cli, null, null, lap.peers);
      addTearDown(sender.dispose);
      lap.outbox.queue('id-Desktop:login', 'local_login', 'ship it', machine: 'id-Desktop');
      final queued = await desk.outbox.pendingStream.firstWhere((p) => p.isNotEmpty);
      expect(
        (queued.single.threadId, queued.single.sessionId, queued.single.text),
        ('login', 'local_login', 'ship it'),
      );
      expect(queued.single.machine, isNull);
      await lap.outbox.pendingStream.firstWhere((p) => p.isEmpty);
      expect(cli.calls, 0, reason: 'the desktop delivers it, not the laptop');

      lap.outbox.queue('id-Desktop:nope', 's', 'hi', machine: 'id-Desktop');
      await sender.statusStream.firstWhere((s) => s.values.any((v) => v.contains('No such thread on Desktop')));

      // Unpairing on one side unpairs both.
      await lap.peers.forget('id-Desktop');
      expect(lap.peers.peers, isEmpty);
      expect(desk.peers.peers, isEmpty);
    },
  );

  test('No on the asked computer pairs nothing', () async {
    final desk = await _Computer.start(tmp, 'Desktop');
    final lap = await _Computer.start(tmp, 'Laptop');
    final pairing = lap.peers.pairWith(desk.url);
    await desk.peers.incomingStream.firstWhere((p) => p != null);
    desk.peers.answerIncoming(false);
    await pairing;
    expect(lap.peers.outgoing!.step, PairingStep.rejected);
    expect(lap.peers.peers, isEmpty);
    expect(desk.peers.peers, isEmpty);
  });

  test('cancelling on the asking computer closes the prompt on the other', () async {
    final desk = await _Computer.start(tmp, 'Desktop');
    final lap = await _Computer.start(tmp, 'Laptop');
    final pairing = lap.peers.pairWith(desk.url);
    await desk.peers.incomingStream.firstWhere((p) => p != null);
    lap.peers.cancelPairing();
    await desk.peers.incomingStream.firstWhere((p) => p == null);
    await pairing;
    expect(desk.peers.peers, isEmpty);
  });

  test('unpaired or forged requests are refused', () async {
    final desk = await _Computer.start(tmp, 'Desktop', threads: [_thread('login')]);
    final client = HttpClient();
    addTearDown(client.close);
    Future<(int, String)> post(String path, Object body) async {
      final req = await client.postUrl(desk.url.resolve(path));
      req.write(jsonEncode(body));
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    expect((await post('/v1/threads', {'from': 'stranger', 'sealed': 'x'})).$1, HttpStatus.unauthorized);
    final forged = await PeerCrypto.seal(List.filled(32, 7), {'ts': DateTime.now().toUtc().toIso8601String()}, 'x');
    expect((await post('/v1/threads', {'from': 'id-Laptop', 'sealed': forged})).$1, HttpStatus.unauthorized);
    final (code, body) = await post('/v1/pair/reveal', {'id': 'x', 'pub': 'AAAA'});
    expect(code, HttpStatus.notFound);
    expect(body, isNot(contains('login')));
  });

  test('an unreachable computer is waited for, not given up on', () async {
    final lap = await _Computer.start(tmp, 'Laptop');
    File(lap.dir.paired).writeAsStringSync(
      jsonEncode([
        // Nothing listens on port 1.
        PairedPeer(id: 'id-Gone', name: 'Gone', url: Uri.parse('http://127.0.0.1:1'), key: List.filled(32, 1)).toJson(),
      ]),
    );
    final again = PeerService(
      lap.dir,
      () => null,
      lap.outbox,
      device: const Device('id-Laptop', 'Laptop'),
      enabled: false,
    );
    addTearDown(again.dispose);
    await again.pollNow();
    expect(again.status.single.error, isNotNull);

    final sender = SendService(lap.outbox, _NoCli(), null, null, again);
    addTearDown(sender.dispose);
    lap.outbox.queue('id-Gone:t', 's', 'hi', machine: 'id-Gone');
    await sender.statusStream.firstWhere((s) => s.values.contains('Waiting for Gone to be reachable'));
  });
}
