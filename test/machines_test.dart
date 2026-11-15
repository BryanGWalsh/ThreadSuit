import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:thread_suit/platform/claude_platform.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/local_threads_service.dart';
import 'package:thread_suit/services/machines_service.dart';
import 'package:thread_suit/services/transcript_parser.dart';

void main() {
  final linux = ClaudePlatform.forOS('linux', env: const {'HOME': '/home/ann'}, fileExists: (_) => false);
  late Directory tmp;
  late DataDir dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('machines');
    dir = DataDir.at(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('machines come from config.json; bad entries are skipped', () {
    File(dir.config).writeAsStringSync(
      jsonEncode({
        'resolve_links': false,
        'machines': [
          {'host': 'laptop', 'os': 'macos', 'name': 'Laptop'},
          {'host': ' me@box '},
          {'host': ''},
          {'os': 'linux'},
          'nope',
        ],
      }),
    );
    final m = MachineConfig.read(dir);
    expect(m.map((m) => (m.host, m.os, m.name)), [('laptop', 'macos', 'Laptop'), ('me@box', 'linux', 'me@box')]);
    expect(MachineConfig.parse(null), isEmpty);
    expect(MachinesService.folderFor('me@box:22'), 'me_box_22');
  });

  test('copies session records and transcripts over ssh, and reports failures', () async {
    final calls = <List<String>>[];
    var fail = false;
    final service = MachinesService(dir, linux, (exe, args) async {
      calls.add([exe, ...args]);
      return ProcessResult(0, fail ? 255 : 0, '', fail ? 'ssh: connect to host laptop: No route to host\n' : '');
    }, const [MachineConfig(host: 'laptop', os: 'macos', name: 'Laptop')]);
    addTearDown(service.dispose);
    await service.syncNow();

    final base = p.join(dir.machines, 'laptop');
    expect(calls.map((c) => c.sublist(c.length - 2)), [
      ['laptop:Library/Application Support/Claude/claude-code-sessions/', '${p.join(base, 'sessions')}/'],
      ['laptop:.claude/projects/', '${p.join(base, 'projects')}/'],
    ]);
    final ok = service.status.single;
    expect(ok.error, isNull);
    expect(ok.syncedAt, isNotNull);
    expect(ok.ready, isTrue);

    fail = true;
    await service.syncNow();
    final bad = service.status.single;
    expect(bad.error, 'ssh: connect to host laptop: No route to host');
    // The last good copy is still shown.
    expect(bad.syncedAt, ok.syncedAt);
  });

  test('a missing folder on the other computer is not an error; Windows computers are not read yet', () async {
    final calls = <String>[];
    final service = MachinesService(dir, linux, (exe, args) async {
      calls.add(args.last);
      return ProcessResult(0, 23, '', 'rsync: change_dir "/x" failed: No such file or directory (2)');
    }, const [MachineConfig(host: 'a'), MachineConfig(host: 'w', os: 'windows')]);
    addTearDown(service.dispose);
    await service.syncNow();
    expect(service.status[0].error, isNull);
    expect(service.status[1].error, contains('Windows'));
    expect(calls, hasLength(2)); // only machine a
  });

  test('no machines configured: nothing runs', () async {
    var ran = false;
    final service = MachinesService(dir, linux, (exe, args) async {
      ran = true;
      return ProcessResult(0, 0, '', '');
    });
    addTearDown(service.dispose);
    expect(service.machines, isEmpty);
    expect(service.status, isEmpty);
    expect(ran, isFalse);
  });

  test("a copied computer's sessions are scanned and carry its name", () {
    void session(String root, String id, String cwd, String folder, String text) {
      final sessions = Directory(p.join(root, 'sessions', 'x'))..createSync(recursive: true);
      File(
        p.join(sessions.path, 'local_$id.json'),
      ).writeAsStringSync(jsonEncode({'sessionId': 'local_$id', 'cliSessionId': id, 'cwd': cwd, 'title': 'T $id'}));
      final t = Directory(p.join(root, 'projects', folder))..createSync(recursive: true);
      File(p.join(t.path, '$id.jsonl')).writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'uuid': 'u-$id',
          'timestamp': '2026-11-15T10:00:00Z',
          'message': {'role': 'user', 'content': text},
        })}\n',
      );
    }

    final here = p.join(tmp.path, 'here'), there = p.join(tmp.path, 'there');
    session(here, 'a1', '/home/ann/app', '-home-ann-app', 'hello from here');
    // A Mac's folder names, read on this computer.
    session(there, 'b2', '/Users/ann/app', '-Users-ann-app', 'hello from there');

    final out = scanSources({
      'cache': <String, dynamic>{},
      'sources': [
        {'sessions_dir': p.join(here, 'sessions'), 'transcripts_dir': p.join(here, 'projects'), 'os': 'linux'},
        {
          'sessions_dir': p.join(there, 'sessions'),
          'transcripts_dir': p.join(there, 'projects'),
          'os': 'macos',
          'machine': 'Laptop',
        },
        // Not copied yet: skipped quietly.
        {'sessions_dir': p.join(tmp.path, 'none'), 'transcripts_dir': p.join(tmp.path, 'none'), 'os': 'linux'},
      ],
    });
    final sessions = (out['sessions'] as List).cast<Map<String, dynamic>>();
    expect({for (final s in sessions) s['local_id']: s['machine']}, {'local_a1': null, 'local_b2': 'Laptop'});
    expect(out['changed'], isTrue);
    final cache = out['cache'] as Map<String, dynamic>;
    final remote = sessions.firstWhere((s) => s['machine'] == 'Laptop')['transcript'] as String;
    expect(TranscriptState.fromJson(cache[remote] as Map<String, dynamic>).messages.single.text, 'hello from there');
  });
}
