import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import 'data_dir.dart';

/// Queues messages as one file each in outbox/. [SendService] delivers each
/// one and deletes its file, so whatever is still in the folder is pending.
class OutboxService implements InjectableWithDisposeInterface {
  final DataDir _dir;
  final _pending = BehaviorSubject<List<OutboxMessage>>.seeded(const []);
  Timer? _timer;

  Stream<List<OutboxMessage>> get pendingStream => _pending.stream;

  OutboxService(this._dir) {
    _scan();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _scan());
  }

  void queue(String threadId, String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now().toUtc();
    final id = '${now.millisecondsSinceEpoch}-${Random().nextInt(1 << 32).toRadixString(16)}';
    final msg = OutboxMessage(id: id, threadId: threadId, sessionId: sessionId, text: trimmed, queuedAt: now);
    // Write to a temp name first so the sender never reads a partial file.
    final tmp = File(p.join(_dir.outbox, '.$id.tmp'));
    tmp.writeAsStringSync(jsonEncode(msg.toJson()));
    tmp.renameSync(p.join(_dir.outbox, '$id.json'));
    _scan();
  }

  /// Removes a message once it's delivered, or when you cancel it.
  void remove(OutboxMessage m) => cancel(m);

  void cancel(OutboxMessage m) {
    final f = File(p.join(_dir.outbox, '${m.id}.json'));
    if (f.existsSync()) f.deleteSync();
    _scan();
  }

  void _scan() {
    final out = <OutboxMessage>[];
    for (final e in Directory(_dir.outbox).listSync()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        out.add(OutboxMessage.fromJson(jsonDecode(e.readAsStringSync()) as Map<String, dynamic>));
      } catch (_) {
        /* skip unreadable files */
      }
    }
    out.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    final cur = _pending.value;
    if (cur.length == out.length && Iterable.generate(out.length).every((i) => cur[i].id == out[i].id)) return;
    _pending.add(out);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _pending.close();
  }
}
