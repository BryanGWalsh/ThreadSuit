import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/services/transcript_parser.dart';

String wake(String id, String sentAt, String text) =>
    '<wake reason="mention"><project id="chan_P" type="project"><thread ts="cmsg_T">'
    '<message trigger="true" from="human" trust="principal" author="Bryan" id="$id" sent-at="$sentAt">$text</message>'
    '</thread></project></wake>';

void main() {
  test('messages sent while the session was busy are read from queued entries, once each', () {
    final tmp = Directory.systemTemp.createTempSync('queued');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final lines = [
      {'type': 'user', 'timestamp': '2026-11-09T13:00:01Z', 'message': {'content': wake('m1', '2026-11-09T13:00:00Z', 'first')}},
      // Sent mid-turn: queued, then delivered as an attachment, never as a user entry.
      {'type': 'queue-operation', 'operation': 'enqueue', 'timestamp': '2026-11-09T13:01:00Z', 'content': wake('m2', '2026-11-09T13:01:00Z', 'second')},
      {'type': 'attachment', 'timestamp': '2026-11-09T13:01:05Z', 'attachment': {'type': 'queued_command', 'prompt': wake('m2', '2026-11-09T13:01:00Z', 'second')}},
      // Queued only (the turn ended before it was delivered).
      {'type': 'queue-operation', 'operation': 'enqueue', 'timestamp': '2026-11-09T13:02:00Z', 'content': wake('m3', '2026-11-09T13:02:00Z', 'third &#39;q&#39;')},
      // Removing a queued prompt is not a message.
      {'type': 'queue-operation', 'operation': 'remove', 'timestamp': '2026-11-09T13:02:01Z', 'content': wake('m9', '2026-11-09T13:02:01Z', 'gone')},
      // Other queued commands (task notifications) are ignored.
      {'type': 'attachment', 'timestamp': '2026-11-09T13:03:00Z', 'attachment': {'type': 'queued_command', 'prompt': '<task-notification>done</task-notification>'}},
    ];
    final f = File('${tmp.path}/t.jsonl')..writeAsStringSync(lines.map((l) => '${jsonEncode(l)}\n').join());
    final s = TranscriptState()..readFrom(f);
    expect(s.messages.where((m) => m.fromHuman).map((m) => m.text), ['first', 'second', "third 'q'"]);
    expect(s.threadId, 'cmsg_T');
  });
}
