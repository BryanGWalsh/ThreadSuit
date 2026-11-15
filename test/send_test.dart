import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/platform/claude_platform.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/machines_service.dart';
import 'package:thread_suit/services/outbox_service.dart';
import 'package:thread_suit/services/send_service.dart';

class _FailingCli extends ClaudeCli {
  int calls = 0;
  @override
  Future<String?> sendToSession(String sessionName, String text, {MachineConfig? machine}) async {
    calls++;
    return 'Claude said no';
  }
}

class _RecordingCli extends ClaudeCli {
  final sent = <(String, String, String?)>[];
  @override
  Future<String?> sendToSession(String sessionName, String text, {MachineConfig? machine}) async {
    sent.add((sessionName, text, machine?.host));
    return null;
  }
}

void main() {
  test('a failing send is tried at most 3 times, further apart each time', () async {
    final root = Directory.systemTemp.createTempSync('send');
    // A "running" session: this test process's own pid, so the liveness check passes.
    final sessions = Directory('${root.path}/claude/sessions')..createSync(recursive: true);
    File(
      '${sessions.path}/1.json',
    ).writeAsStringSync(jsonEncode({'hostSessionId': 'local_1', 'pid': pid, 'name': 'demo'}));
    final platform = ClaudePlatform.forOS(
      'linux',
      env: {'HOME': root.path, 'CLAUDE_CONFIG_DIR': '${root.path}/claude'},
    );

    var clock = DateTime(2026, 11, 7, 12);
    final dir = DataDir.at('${root.path}/data');
    final outbox = OutboxService(dir);
    final cli = _FailingCli();
    final sender = SendService(outbox, cli, platform, () => clock);
    outbox.queue('t1', 'local_1', 'hello');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sender.deliverNow();
    final first = cli.calls;
    expect(first, 1);

    await sender.deliverNow(); // too soon: no call
    expect(cli.calls, first);
    clock = clock.add(const Duration(minutes: 1));
    await sender.deliverNow();
    expect(cli.calls, 2);
    clock = clock.add(const Duration(minutes: 2));
    await sender.deliverNow(); // second wait is 5 minutes
    expect(cli.calls, 2);
    clock = clock.add(const Duration(minutes: 3));
    await sender.deliverNow();
    expect(cli.calls, 3);
    clock = clock.add(const Duration(hours: 5));
    await sender.deliverNow(); // gave up
    expect(cli.calls, 3);
    expect((await sender.statusStream.first).values.single, startsWith('Not sent after 3 tries'));
    await sender.dispose();
    root.deleteSync(recursive: true);
  });

  test("a message for another computer's thread is checked and sent there", () async {
    final root = Directory.systemTemp.createTempSync('send');
    final platform = ClaudePlatform.forOS(
      'linux',
      env: {'HOME': root.path, 'CLAUDE_CONFIG_DIR': '${root.path}/claude'},
    );
    final dir = DataDir.at('${root.path}/data');
    final checks = <List<String>>[];
    var alive = false;
    final machines = MachinesService(dir, platform, (exe, args) async {
      if (exe == 'ssh') checks.add(args);
      return ProcessResult(0, exe == 'ssh' && !alive ? 1 : 0, '', '');
    }, const [MachineConfig(host: 'me@laptop', name: 'Laptop')]);
    await machines.syncNow();
    // The copy of the laptop's running-session records.
    final running = Directory(machines.status.single.runningDir)..createSync(recursive: true);
    File(
      '${running.path}/9.json',
    ).writeAsStringSync(jsonEncode({'hostSessionId': 'local_9', 'pid': 4242, 'name': 'far'}));

    final outbox = OutboxService(dir);
    final cli = _RecordingCli();
    final sender = SendService(outbox, cli, platform, null, machines);
    outbox.queue('t9', 'local_9', 'hi there', machine: 'Laptop');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await sender.deliverNow(); // not running there yet: no Claude call
    expect(cli.sent, isEmpty);
    expect(checks.last.sublist(checks.last.length - 2), ['me@laptop', 'kill -0 4242']);
    expect((await sender.statusStream.first).values.single, contains('on Laptop'));

    alive = true;
    await sender.deliverNow();
    expect(cli.sent, [('far', 'hi there', 'me@laptop')]);
    expect(outbox.pendingStream, emits(isEmpty));

    await sender.dispose();
    await machines.dispose();
    root.deleteSync(recursive: true);
  });
}
