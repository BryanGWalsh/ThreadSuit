import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/models/models.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/transcript_parser.dart';
import 'package:thread_suit/services/outbox_service.dart';
import 'package:thread_suit/services/seen_service.dart';
import 'package:thread_suit/services/sleep_service.dart';
import 'package:thread_suit/services/workspace_service.dart';
import 'package:thread_suit/ui/tile_grid.dart';

ThreadSummary thread(String last, {List<Map<String, dynamic>>? extra, String? asOf}) => ThreadSummary.fromJson({
      'messages_as_of': asOf ?? last,
      'thread_id': 't1',
      'title': 'A thread',
      'state': 'blocked',
      'last_activity_at': last,
      'messages': [
        {'id': 'm2', 'from_human': false, 'sent_at': '2026-11-06T10:05:00Z', 'text': 'second'},
        {'id': 'm1', 'from_human': true, 'author': 'Sam', 'sent_at': '2026-11-06T10:00:00Z', 'text': 'first'},
        ...?extra,
      ],
    });

void main() {
  late Directory tmp;
  late DataDir dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('td');
    dir = DataDir.at(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('parses state and sorts messages oldest first', () {
    final t = thread('2026-11-06T10:05:00Z');
    expect(t.state, ThreadState.blocked);
    expect(t.messages.map((m) => m.text), ['first', 'second']);
  });

  test('thread is unread until seen, and unread again after new activity', () async {
    final seen = SeenService(dir);
    final t = thread('2026-11-06T10:05:00Z');
    expect(SeenService.isUnread(t, {}), isTrue);
    seen.markSeen(t);
    final map = await seen.seenStream.first;
    expect(SeenService.isUnread(t, map), isFalse);
    expect(SeenService.isUnread(thread('2026-11-06T11:00:00Z'), map), isTrue);
    // Persists across restarts.
    expect(SeenService.isUnread(t, await SeenService(dir).seenStream.first), isFalse);
  });

  test('queued messages are files in outbox until the sync deletes them', () async {
    final outbox = OutboxService(dir);
    outbox.queue('t1', 'local_1', '  hello  ');
    final files = Directory(dir.outbox).listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    final json = jsonDecode(files.single.readAsStringSync());
    expect(json['thread_id'], 't1');
    expect(json['text'], 'hello');
    expect((await outbox.pendingStream.first).single.text, 'hello');
    await outbox.dispose();
  });

  test('asleep thread stays asleep through status notices and wakes on a new message', () async {
    final sleep = SleepService(dir);
    final t = thread('2026-11-06T10:05:00Z');
    sleep.sleep(t);
    expect(SleepService.isAsleep(t, sleep.value), isTrue);

    final notice = thread('2026-11-06T11:00:00Z', extra: [
      {'id': 'e1', 'kind': 'event', 'sent_at': '2026-11-06T11:00:00Z', 'text': 'went offline'},
    ]);
    expect(SleepService.isAsleep(notice, sleep.value), isTrue);

    final reply = thread('2026-11-06T12:00:00Z', extra: [
      {'id': 'm3', 'from_human': false, 'sent_at': '2026-11-06T12:00:00Z', 'text': 'done'},
    ]);
    expect(SleepService.isAsleep(reply, sleep.value), isFalse);

    // Activity newer than the stored messages may be a message, so it wakes.
    expect(SleepService.isAsleep(thread('2026-11-06T12:00:00Z', asOf: '2026-11-06T10:05:00Z'), sleep.value), isFalse);
    // Persists across restarts.
    expect(SleepService.isAsleep(t, SleepService(dir).value), isTrue);
  });

  test('each opened thread adds a tile, up to nine, oldest closing first', () async {
    final ws = WorkspaceService();
    for (var i = 0; i < 10; i++) {
      ws.open('t$i');
    }
    ws.open('t5'); // already open: no change
    final open = await ws.openStream.first;
    expect(open, [for (var i = 1; i < 10; i++) 't$i']);
    expect([1, 2, 3, 4, 5, 6, 7, 9].map((n) => TileGrid.gridFor(n).cols), [1, 2, 2, 2, 3, 3, 3, 3]);
  });

  test('reads your messages and Claude replies from a project thread transcript, incrementally', () {
    String line(Map<String, dynamic> e) => '${jsonEncode(e)}\n';
    final wake = '<wake reason="mention"><project id="chan_P" type="project"><thread ts="cmsg_T">'
        '<message trigger="true" from="human" trust="principal" author="Sam" id="cmsg_M1" sent-at="2026-11-06T10:00:00Z">'
        'can you check &#39;it&#39;?</message></thread></project></wake>';
    final f = File('${tmp.path}/t.jsonl')
      ..writeAsStringSync(line({
        'type': 'user',
        'timestamp': '2026-11-06T10:00:01Z',
        'message': {'content': wake}
      }));
    final s = TranscriptState()..readFrom(f);
    expect(s.threadId, 'cmsg_T');
    expect(s.projectId, 'chan_P');
    expect(s.messages.single.text, "can you check 'it'?");

    f.writeAsStringSync(
        '${line({
          'type': 'assistant',
          'timestamp': '2026-11-06T10:01:00Z',
          'message': {
            'content': [
              {'type': 'tool_use', 'id': 'tu1', 'name': 'mcp__hearthbot__post_message', 'input': {'text': 'Checked, all good.'}},
              {'type': 'tool_use', 'id': 'tu2', 'name': 'mcp__hearthbot__rename_thread', 'input': {'title': 'Check it'}},
            ]
          }
        })}{"type":"user","partial',
        mode: FileMode.append);
    s.readFrom(f);
    expect(s.messages.map((m) => m.text), ["can you check 'it'?", 'Checked, all good.']);
    expect(s.messages.last.fromHuman, isFalse);
    expect(s.renamedTitle, 'Check it');
    // The partial last line is left for the next read.
    expect(s.offset, lessThan(f.lengthSync()));
  });

  test('opening a thread that is already open asks its tile to flash', () async {
    final ws = WorkspaceService();
    final flashes = <String>[];
    ws.highlightStream.listen(flashes.add);
    ws.open('a');
    ws.open('b');
    ws.open('a');
    await Future<void>.delayed(Duration.zero);
    expect(flashes, ['a']);
    expect(await ws.openStream.first, ['a', 'b']);
    // Newly opened tiles flash once when they first appear.
    expect(ws.takeJustOpened('b'), isTrue);
    expect(ws.takeJustOpened('b'), isFalse);
  });
}
