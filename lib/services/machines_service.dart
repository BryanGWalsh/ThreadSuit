import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

import '../platform/claude_platform.dart';
import 'data_dir.dart';

/// Another computer whose Claude threads Thread Suit shows, from the
/// `machines` list in `config.json`:
///
/// ```json
/// {"machines": [{"host": "laptop", "os": "macos", "name": "Laptop"}]}
/// ```
///
/// `host` is what you'd pass to `ssh` (a name from your SSH config, or
/// `user@host`); `os` is `macos`, `linux` or `windows` (default `linux`);
/// `name` is how the list labels its threads (default the host).
class MachineConfig {
  final String host;
  final String os;
  final String name;

  const MachineConfig({required this.host, this.os = 'linux', String? name}) : name = name ?? host;

  static List<MachineConfig> parse(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final m in raw)
        if (m is Map && m['host'] is String && (m['host'] as String).trim().isNotEmpty)
          MachineConfig(
            host: (m['host'] as String).trim(),
            os: m['os'] is String ? m['os'] as String : 'linux',
            name: m['name'] is String && (m['name'] as String).trim().isNotEmpty ? (m['name'] as String).trim() : null,
          ),
    ];
  }

  static List<MachineConfig> read(DataDir dir) {
    try {
      return parse((jsonDecode(File(dir.config).readAsStringSync()) as Map)['machines']);
    } catch (_) {
      return const [];
    }
  }
}

/// Where a machine's copied files are, and how the last copy went.
class MachineStatus {
  final MachineConfig config;

  /// The local copies of its desktop session records and transcripts.
  final String sessionsDir;
  final String transcriptsDir;

  /// The local copy of its running-session records (Claude Code's
  /// `sessions/*.json`), to find where to deliver a message.
  String get runningDir => p.join(p.dirname(sessionsDir), 'running');

  /// When a copy last succeeded; null if none has yet.
  final DateTime? syncedAt;

  /// Why the last copy failed; null if it worked.
  final String? error;

  const MachineStatus(this.config, this.sessionsDir, this.transcriptsDir, {this.syncedAt, this.error});

  bool get ready => syncedAt != null || Directory(sessionsDir).existsSync();
}

typedef ProcessRunner = Future<ProcessResult> Function(String exe, List<String> args);

/// Copies the Claude session files of your other computers to this one, over
/// your own SSH login, so their threads show up next to this computer's.
/// No AI calls and no Claude login: only `rsync` over `ssh`, read-only on
/// the other computer. The copies live in `~/.thread-suit/machines/<host>/`
/// and are parsed like this computer's files.
class MachinesService implements InjectableWithDisposeInterface {
  static const interval = Duration(seconds: 60);

  final DataDir _dir;
  final ClaudePlatform _platform;
  final ProcessRunner _run;
  final List<MachineConfig> machines;
  final _status = BehaviorSubject<List<MachineStatus>>.seeded(const []);
  Timer? _timer;
  Future<void>? _running;

  Stream<List<MachineStatus>> get statusStream => _status.stream;
  List<MachineStatus> get status => _status.value;

  MachinesService(this._dir, [ClaudePlatform? platform, ProcessRunner? run, List<MachineConfig>? machines])
    : _platform = platform ?? ClaudePlatform.current,
      _run =
          run ??
          ((exe, args) => Process.run(exe, args, environment: (platform ?? ClaudePlatform.current).toolEnvironment)),
      machines = machines ?? MachineConfig.read(_dir) {
    if (this.machines.isEmpty) return;
    _status.add([for (final m in this.machines) _initial(m)]);
    unawaited(syncNow());
    _timer = Timer.periodic(interval, (_) => syncNow());
  }

  /// A folder name for [host] that's safe on every OS.
  static String folderFor(String host) => host.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  MachineStatus _initial(MachineConfig m) {
    final base = p.join(_dir.machines, folderFor(m.host));
    return MachineStatus(m, p.join(base, 'sessions'), p.join(base, 'projects'));
  }

  /// Copies every machine once, one after another. While a copy is running,
  /// returns that one instead of starting another.
  @visibleForTesting
  Future<void> syncNow() => _running ??= _syncAll().whenComplete(() => _running = null);

  Future<void> _syncAll() async {
    {
      for (var i = 0; i < machines.length; i++) {
        final before = _status.value[i];
        final error = await _sync(before);
        final next = [..._status.value];
        next[i] = MachineStatus(
          before.config,
          before.sessionsDir,
          before.transcriptsDir,
          syncedAt: error == null ? DateTime.now() : before.syncedAt,
          error: error,
        );
        if (!_status.isClosed) _status.add(next);
      }
    }
  }

  /// Copies [m]'s records and transcripts; returns why it failed, or null.
  Future<String?> _sync(MachineStatus m) async {
    final remote = ClaudePlatform.forOS(m.config.os, env: const {}, fileExists: (_) => false);
    if (remote.name == 'windows') return "Reading a Windows computer isn't supported yet";
    final copies = [
      ('${remote.desktopDirFromHome}/claude-code-sessions', m.sessionsDir),
      // Like Claude Code's default; CLAUDE_CONFIG_DIR on the other computer isn't known.
      ('.claude/projects', m.transcriptsDir),
      // Only the .json records; the .key files next to them stay there.
      ('.claude/sessions', m.runningDir),
    ];
    for (final (from, to) in copies) {
      final cmd = _platform.mirrorCommand(host: m.config.host, remoteDir: from, localDir: to);
      if (cmd == null) return "Reading other computers isn't supported on this OS yet";
      Directory(to).createSync(recursive: true);
      try {
        final r = await _run(cmd.first, cmd.sublist(1));
        final error = r.exitCode == 0 ? null : _explain(r.exitCode, '${r.stderr}');
        if (error != null) return error;
      } on ProcessException catch (e) {
        return 'Could not run ${cmd.first}: ${e.message}';
      }
    }
    return null;
  }

  /// A short reason for a failed copy. rsync exit 23 with "No such file"
  /// just means the other computer has no such folder (no desktop app, or no
  /// Code sessions yet), so it isn't an error.
  static String? _explain(int code, String stderr) {
    if (code == 23 && stderr.contains('No such file')) return null;
    final line = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
    return line ?? 'rsync exited with $code';
  }

  /// The machine called [name] (a thread's `machine`), if it's configured.
  MachineStatus? byName(String? name) => name == null ? null : status.where((m) => m.config.name == name).firstOrNull;

  /// Whether process [pid] runs on [machine], checked over SSH. Free: no AI.
  Future<bool> isProcessAlive(MachineConfig machine, int pid) async {
    final check = ClaudePlatform.forOS(machine.os, env: const {}, fileExists: (_) => false).remoteProcessCheck(pid);
    if (check == null) return false;
    final cmd = _platform.sshCommand(machine.host, check);
    try {
      return (await _run(cmd.first, cmd.sublist(1))).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _status.close();
  }
}
