// ignore_for_file: avoid_print
// Times a full scan of this Mac's sessions and prints what it found.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/link_service.dart';
import 'package:thread_suit/services/local_threads_service.dart';

void main() {
  test('scan', () async {
    final src = Platform.environment['SNAPSHOT_DIR']!;
    final dir = DataDir.at(src);
    final sw = Stopwatch()..start();
    final svc = LocalThreadsService(dir, LinkService(dir, ClaudeCli()));
    final s = await svc.stateStream.firstWhere((s) => s.snapshot != null || s.error != null).timeout(const Duration(minutes: 5));
    print('took ${sw.elapsed}, error: ${s.error}');
    final threads = s.snapshot!.threads..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    print('${threads.length} threads');
    for (final t in threads.take(12)) {
      print('${t.lastActivityAt.toLocal()} | ${t.project ?? 'none'} | ${t.title} | ${t.messages.length} msgs | resolved ${t.resolved} | ${t.links.map((l) => l.key).join(' ')}');
    }
    await svc.dispose();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
