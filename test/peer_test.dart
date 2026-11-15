import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/models/models.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/outbox_service.dart';
import 'package:thread_suit/services/peer_service.dart';
import 'package:thread_suit/services/send_service.dart';
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('peer'));
  tearDown(() => tmp.deleteSync(recursive: true));

  DataDir dataDir(String name) => DataDir.at('${tmp.path}/$name');

  test('config: share makes and saves a token, keeping other keys; bad peers are skipped', () {
    final dir = dataDir('a');
    File(dir.config).writeAsStringSync(
      jsonEncode({
        'resolve_links': false,
        'share': {'port': 5000, 'token': 'short'},
      }),
    );
    final share = ShareConfig.read(dir)!;
    expect(share.port, 5000);
    expect(share.token.length, greaterThanOrEqualTo(ShareConfig.minTokenLength));
    final saved = jsonDecode(File(dir.config).readAsStringSync()) as Map;
    expect(saved['resolve_links'], false);
    expect(saved['share']['token'], share.token);
    expect(ShareConfig.read(dir)!.token, share.token, reason: 'made only once');

    expect(ShareConfig.read(dataDir('none')), isNull, reason: 'off without a share entry');

    final peers = PeerConfig.parse([
      {'name': 'Lap:top', 'url': 'http://10.0.0.2:47322', 'token': 't'},
      {'url': 'https://box.example:9', 'token': 't'},
      {'url': 'ftp://x', 'token': 't'},
      {'url': 'http://x'},
      'nope',
    ]);
    expect(peers.map((p) => p.name), ['Lap top', 'box.example']);
  });

  test('a thread survives the trip: toJson, fromJson, tagged with its computer', () {
    final back = ThreadSummary.fromJson(jsonDecode(jsonEncode(_thread('login').toJson())) as Map<String, dynamic>);
    final t = back.onMachine('Laptop');
    expect(t.threadId, 'Laptop:login');
    expect(t.machine, 'Laptop');
    expect(t.sessionId, 'local_login');
    expect(t.title, 'Fix the login');
    expect(t.messages.map((m) => (m.text, m.fromHuman, m.isNotes)), [('go', true, false), ('done', false, true)]);
    expect(origin(t), 'Project: Shop · on Laptop');
    expect(origin(_thread('x')), 'Project: Shop');
  });

  test("two copies: one reads the other's threads and replies; the owner queues the reply", () async {
    // Desktop shares its threads; Laptop reads them.
    final deskDir = dataDir('desk'), lapDir = dataDir('lap');
    final deskOutbox = OutboxService(deskDir), lapOutbox = OutboxService(lapDir);
    addTearDown(deskOutbox.dispose);
    addTearDown(lapOutbox.dispose);
    final token = ShareConfig.newToken();
    final desk = PeerService(
      deskDir,
      () => Snapshot(generatedAt: DateTime.now(), projectName: '', threads: [_thread('login')]),
      deskOutbox,
      share: ShareConfig(port: 0, address: '127.0.0.1', token: token),
      read: false,
    );
    addTearDown(desk.dispose);
    while (desk.sharePort == null) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    PeerService reader(String withToken) => PeerService(
      lapDir,
      () => null,
      lapOutbox,
      peers: [PeerConfig(name: 'Desktop', url: Uri.parse('http://127.0.0.1:${desk.sharePort}'), token: withToken)],
      read: false,
    );

    final wrong = reader('x' * 64);
    addTearDown(wrong.dispose);
    await wrong.pollNow();
    expect(wrong.status.single.threads, isEmpty);
    expect(wrong.status.single.error, 'Wrong or missing token');

    final lap = reader(token);
    addTearDown(lap.dispose);
    await lap.pollNow();
    final seen = lap.status.single;
    expect(seen.error, isNull);
    expect(seen.threads.single.threadId, 'Desktop:login');
    expect(seen.threads.single.machine, 'Desktop');

    // A reply typed on the laptop goes to the desktop's outbox, with no Claude call here.
    final cli = _NoCli();
    final sender = SendService(lapOutbox, cli, null, null, lap);
    addTearDown(sender.dispose);
    // Delivery starts by itself once the outbox shows the message.
    lapOutbox.queue('Desktop:login', 'local_login', 'ship it', machine: 'Desktop');
    final queued = await deskOutbox.pendingStream.firstWhere((p) => p.isNotEmpty);
    expect(queued.single.threadId, 'login');
    expect(queued.single.sessionId, 'local_login');
    expect(queued.single.text, 'ship it');
    expect(queued.single.machine, isNull);
    await lapOutbox.pendingStream.firstWhere((p) => p.isEmpty);
    expect(cli.calls, 0);

    // Unknown threads are refused for good, not retried.
    lapOutbox.queue('Desktop:nope', 's', 'hi', machine: 'Desktop');
    await sender.statusStream.firstWhere((s) => s.values.any((v) => v.contains('No such thread')));
    await sender.deliverNow();
    expect(lapOutbox.pendingStream, emits(hasLength(1)), reason: 'kept, marked not sent');
  });

  test('an unreachable peer keeps its last threads and is retried', () async {
    final dir = dataDir('c');
    final outbox = OutboxService(dir);
    addTearDown(outbox.dispose);
    final p = PeerService(
      dir,
      () => null,
      outbox,
      // Nothing listens on port 1.
      peers: [PeerConfig(name: 'Gone', url: Uri.parse('http://127.0.0.1:1'), token: 't')],
      read: false,
    );
    addTearDown(p.dispose);
    await p.pollNow();
    expect(p.status.single.error, isNotNull);

    final sender = SendService(outbox, _NoCli(), null, null, p);
    addTearDown(sender.dispose);
    outbox.queue('Gone:t', 's', 'hi', machine: 'Gone');
    await sender.statusStream.firstWhere((s) => s.values.contains('Waiting for Gone to be reachable'));
  });
}
