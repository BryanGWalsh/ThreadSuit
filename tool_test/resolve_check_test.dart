// ignore_for_file: avoid_print
// Runs one real Haiku link lookup for one of this computer's threads and
// prints the summary it read, the links it returned and what it cost. Not
// part of the normal test run, and it spends a few tokens:
//   SNAPSHOT_DIR=~/.thread-suit TITLE='part of a title' flutter test tool_test/resolve_check_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/models/models.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/link_detector.dart';
import 'package:thread_suit/services/link_service.dart';
import 'package:thread_suit/services/local_threads_service.dart';

class _Capture extends LinkService {
  final digests = <String, LinkDigest>{};
  _Capture(DataDir dir) : super(dir, ClaudeCli(), enabled: false);

  @override
  List<ThreadLink> linksFor(String threadId, LinkDigest digest) {
    digests[threadId] = digest;
    return super.linksFor(threadId, digest);
  }
}

void main() {
  test('resolve', () async {
    final dir = DataDir.at(Platform.environment['SNAPSHOT_DIR']!);
    final want = (Platform.environment['TITLE'] ?? '').toLowerCase();
    final links = _Capture(dir);
    final svc = LocalThreadsService(dir, links);
    final s = await svc.stateStream.firstWhere((s) => s.snapshot != null).timeout(const Duration(minutes: 2));
    final thread = s.snapshot!.threads.firstWhere((t) => t.title.toLowerCase().contains(want));
    final digest = links.digests[thread.threadId]!;
    final tools = ClaudeCli.linkLookupTools(links.knownTools, links.readCommands);
    print('Thread: ${thread.title}\n--- summary (${digest.text.length} chars) ---\n${digest.text}');
    print('--- tools ---\n${tools.join('\n')}');

    final cli = ClaudeCli();
    final sw = Stopwatch()..start();
    if (!digest.hasEvidence) print('--- no evidence: the app would not call Haiku for this thread ---');
    final run = await cli.resolveLinks(digest.text, tools);
    print('--- took ${sw.elapsed}, usage: ${cli.lastUsage} ---');
    print('raw: ${run?.items}');
    if (run == null) print('failed: ${cli.lastError}');
    print('--- tool calls ---\n${cli.lastToolCalls}');
    print('--- tool results (${run?.toolResults.length ?? 0} chars) ---\n${(run?.toolResults ?? '').substring(0, (run?.toolResults.length ?? 0).clamp(0, 1500))}');
    final valid = run == null
        ? null
        : LinkDetector.validate(run.items.map(ResolvedLink.fromJson).nonNulls, '${digest.evidence}\n${run.toolResults}');
    for (final l in valid ?? const <ResolvedLink>[]) {
      print('${l.kind.name} | ${l.label} | ${l.title} | ${l.state} | ${l.url}');
    }
    await svc.dispose();
    await links.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
