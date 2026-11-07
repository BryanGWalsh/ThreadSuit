import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import '../platform/claude_platform.dart';
import 'claude_cli.dart';
import 'outbox_service.dart';

/// Delivers queued messages to their thread's running Claude session on this
/// computer, one short Haiku `claude -p` call per message. A message for a thread
/// whose session isn't running waits until it is.
class SendService implements InjectableWithDisposeInterface {
  final OutboxService _outbox;
  final ClaudeCli _cli;
  final _status = BehaviorSubject<Map<String, String>>.seeded(const {});
  late final StreamSubscription _sub;
  Timer? _timer;
  bool _sending = false;
  List<OutboxMessage> _pending = const [];

  /// Outbox id -> what's happening with it ("Sending…", "Waiting for…", an error).
  Stream<Map<String, String>> get statusStream => _status.stream;

  final ClaudePlatform _platform;

  SendService(this._outbox, this._cli, [ClaudePlatform? platform]) : _platform = platform ?? ClaudePlatform.current {
    _sub = _outbox.pendingStream.listen((p) {
      _pending = p;
      _deliver();
    });
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _deliver());
  }

  /// Name of the live CLI process serving the desktop session [localId], if any.
  Future<String?> runningSessionName(String localId) async {
    final dir = Directory(_platform.runningSessionsDir);
    if (!dir.existsSync()) return null;
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      try {
        final d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (d['hostSessionId'] != localId) continue;
        final pid = d['pid'] as int?;
        if (pid == null) continue;
        if (await _platform.isProcessAlive(pid)) return d['name'] as String?;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _deliver() async {
    if (_sending) return;
    _sending = true;
    try {
      for (final m in List.of(_pending)) {
        final name = await runningSessionName(m.sessionId);
        if (name == null) {
          _set(m.id, "Waiting for the thread's session to start on this computer");
          continue;
        }
        _set(m.id, 'Sending…');
        String? error;
        try {
          error = await _cli.sendToSession(name, m.text);
        } catch (e) {
          error = '$e';
        }
        if (error == null) {
          _outbox.remove(m);
          _set(m.id, null);
        } else {
          _set(m.id, 'Not sent: $error');
        }
      }
    } finally {
      _sending = false;
    }
  }

  void _set(String id, String? status) {
    final next = {..._status.value};
    status == null ? next.remove(id) : next[id] = status;
    _status.add(next);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _sub.cancel();
    await _status.close();
  }
}
