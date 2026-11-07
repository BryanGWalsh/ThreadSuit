// ignore_for_file: avoid_print
// Sends one real message through the app's outbox and SendService.
//   SESSION=local_… TEXT='…' flutter test tool_test/send_check_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/outbox_service.dart';
import 'package:thread_suit/services/send_service.dart';

void main() {
  test('send', () async {
    final tmp = Directory.systemTemp.createTempSync('send');
    final outbox = OutboxService(DataDir.at(tmp.path));
    final sender = SendService(outbox, ClaudeCli());
    sender.statusStream.listen((s) => print('status: $s'));
    outbox.queue('test', Platform.environment['SESSION']!, Platform.environment['TEXT']!);
    final left = await outbox.pendingStream.firstWhere((p) => p.isEmpty).timeout(const Duration(minutes: 3));
    print('delivered, outbox empty: ${left.isEmpty}');
    await sender.dispose();
    await outbox.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
