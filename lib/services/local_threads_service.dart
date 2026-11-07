import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import '../platform/claude_platform.dart';
import 'data_dir.dart';
import 'link_service.dart';
import 'transcript_parser.dart';

class SnapshotState {
  final Snapshot? snapshot;
  final String? error;
  const SnapshotState(this.snapshot, this.error);
}

/// Builds the thread list from what the Claude desktop app and Claude Code
/// already keep on this computer, with no AI calls:
///
/// - [ClaudePlatform.desktopSessionsDir]: one record per Code session
///   (title, folder, transcript id, PRs, SSH host).
/// - [ClaudePlatform.transcriptsDir]: each session's transcript, in
///   `<folder>/<id>.jsonl`, or `ssh-<id>/<id>.jsonl` for SSH sessions.
///
/// Only threads whose session ran on this computer appear. Transcripts are read
/// incrementally and the parsed state is cached in `cache.json`.
class LocalThreadsService implements InjectableWithDisposeInterface {
  final DataDir _dir;
  final LinkService _links;
  final ClaudePlatform _platform;
  final _state = BehaviorSubject<SnapshotState>.seeded(const SnapshotState(null, null));
  Timer? _timer;
  bool _busy = false;
  Map<String, dynamic> _cache = {};

  Stream<SnapshotState> get stateStream => _state.stream;

  /// Claude Code hooks POST here when a session gets or sends a message.
  static const notifyPort = 47321;
  HttpServer? _server;

  LocalThreadsService(this._dir, this._links, [ClaudePlatform? platform])
    : _platform = platform ?? ClaudePlatform.current {
    try {
      _cache = jsonDecode(File(_dir.cache).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    _refresh();
    // Hooks make updates instant; this poll is only a fallback for missed pings.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
    _links.changes.listen((_) => _rebuild());
    _listen();
  }

  Future<void> _listen() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, notifyPort);
      _server!.listen((req) {
        req.response
          ..statusCode = HttpStatus.noContent
          ..close();
        if (req.uri.path == '/changed') {
          // The hook can fire just before the transcript line is written.
          _refresh();
          Timer(const Duration(seconds: 1), _refresh);
        }
      });
    } catch (_) {
      // Port busy (another copy running): polling still works.
    }
  }

  List<Map<String, dynamic>> _sessions = [];

  bool _again = false;

  Future<void> _refresh() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      final input = {
        'cache': _cache,
        'sessions_dir': _platform.desktopSessionsDir,
        'transcripts_dir': _platform.transcriptsDir,
        'os': _platform.name,
      };
      final out = await Isolate.run(() => _scan(input));
      _cache = out['cache'] as Map<String, dynamic>;
      _sessions = (out['sessions'] as List).cast<Map<String, dynamic>>();
      if (out['changed'] == true) {
        final tmp = File('${_dir.cache}.tmp')..writeAsStringSync(jsonEncode(_cache));
        tmp.renameSync(_dir.cache);
      }
      _rebuild();
    } catch (e) {
      _state.add(SnapshotState(_state.value.snapshot, 'Could not read local sessions: $e'));
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(_refresh());
      }
    }
  }

  /// Titles the desktop app gives sessions it started for a thread, before
  /// anything better is known. A real title from another session wins.
  static final _genericTitle = RegExp(
    r'^(Remote Control|Local) session \(from a project\)$|^Untitled|^Remote control$',
    caseSensitive: false,
  );

  void _rebuild() {
    final projects = _projectNames();
    // One project thread can span several local sessions (each restart or
    // Remote Control hand-off starts a new one). Group them into one row.
    final groups = <String, List<(Map<String, dynamic>, TranscriptState)>>{};
    for (final s in _sessions) {
      final t = TranscriptState.fromJson(_cache[s['transcript']] as Map<String, dynamic>);
      if (t.messages.isEmpty) continue;
      groups.putIfAbsent(t.threadId ?? s['local_id'] as String, () => []).add((s, t));
    }

    final threads = <ThreadSummary>[];
    groups.forEach((threadId, parts) {
      // Newest session last, so its title, resolved state and session win.
      parts.sort((a, b) => a.$2.messages.last.sentAt.compareTo(b.$2.messages.last.sentAt));
      final byId = <String, ThreadMessage>{};
      for (final (_, t) in parts) {
        for (final m in t.messages) {
          byId[m.id] = ThreadMessage(
            id: m.id,
            author: m.author,
            fromHuman: m.fromHuman,
            sentAt: m.sentAt,
            text: m.text,
          );
        }
      }
      final msgs = byId.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      final keep = msgs.length > TranscriptState.keep ? msgs.sublist(msgs.length - TranscriptState.keep) : msgs;
      final last = keep.last.sentAt;

      String? title;
      bool? resolved;
      String? projectId;
      String? projectName;
      String? firstPrompt;
      var isProject = false;
      final urls = <String>[], shellUrls = <String>[], calls = <String>[], refs = <String>[];
      for (final (s, t) in parts) {
        final candidate = t.renamedTitle ?? s['title'] as String?;
        if (candidate != null && (title == null || !_genericTitle.hasMatch(candidate))) title = candidate;
        if (t.renamedTitle != null) title = t.renamedTitle;
        resolved = t.resolved ?? resolved;
        projectId = t.projectId ?? projectId;
        projectName = t.projectName ?? projectName;
        firstPrompt ??= t.firstPrompt;
        isProject |= t.isProjectThread;
        urls.addAll(t.urls);
        shellUrls.addAll(t.shellUrls);
        calls.addAll(t.toolCalls);
        refs.addAll(t.refs);
        // PRs the desktop app recorded for the session, as plain references.
        for (final pr in (s['prs'] as List?) ?? const []) {
          if (pr is! Map) continue;
          if (pr['url'] is String) urls.add(pr['url'] as String);
          if (pr['repo'] != null && pr['prNumber'] != null) refs.add('${pr['repo']}#${pr['prNumber']}');
        }
      }
      // No real title (Remote Control project sessions get a placeholder):
      // use the start of the first message, as the desktop app's list does.
      if ((title == null || _genericTitle.hasMatch(title)) && firstPrompt != null) title = firstPrompt;
      List<String> unique(List<String> l) => l.reversed.toSet().toList().reversed.toList();
      final digest = LinkDigest(
        urls: unique(urls),
        shellUrls: unique(shellUrls),
        toolCalls: unique(calls),
        refs: unique(refs),
      );
      threads.add(
        ThreadSummary(
          threadId: threadId,
          // Send to the most recent session; it's the one most likely running.
          sessionId: parts.last.$1['local_id'] as String,
          title: title ?? 'Untitled session',
          state: ThreadState.unknown,
          lastActivityAt: last,
          resolved: resolved ?? false,
          messagesAsOf: last,
          messages: keep,
          // projects.json wins, so you can rename a project; then the name
          // from the transcript; then the bare id.
          project: isProject ? (projects[projectId] ?? projectName ?? projectId) : null,
          links: _links.linksFor(threadId, digest),
        ),
      );
    });
    final states = [
      for (final s in _sessions) TranscriptState.fromJson(_cache[s['transcript']] as Map<String, dynamic>),
    ];
    _links
      ..knownTools = {for (final t in states) ...t.toolNames}
      ..readCommands = {for (final t in states) ...t.readCommands};
    _state.add(SnapshotState(Snapshot(generatedAt: DateTime.now(), projectName: '', threads: threads), null));
  }

  /// Project ids to names, from `projects.json` (ids are all a transcript has).
  Map<String, String> _projectNames() {
    try {
      return (jsonDecode(File(_dir.projects).readAsStringSync()) as Map).cast<String, String>();
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _server?.close(force: true);
    await _state.close();
  }
}

/// Runs off the UI isolate: lists sessions and reads new transcript bytes.
Map<String, dynamic> _scan(Map<String, dynamic> input) {
  final cache = Map<String, dynamic>.from(input['cache'] as Map);
  final sessions = <Map<String, dynamic>>[];
  var changed = false;
  final dir = Directory(input['sessions_dir'] as String);
  if (!dir.existsSync()) return {'cache': cache, 'sessions': sessions, 'changed': false};

  for (final f in dir.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.json')) continue;
    Map<String, dynamic> d;
    try {
      d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (d['isArchived'] == true) continue;
    if (d['cliSessionId'] is! String) continue;
    final transcript = transcriptCandidates(
      d,
      input['transcripts_dir'] as String,
      input['os'] as String,
    ).firstWhere((c) => File(c).existsSync(), orElse: () => '');
    if (transcript.isEmpty) continue;
    final file = File(transcript);

    final state = cache[transcript] == null
        ? TranscriptState()
        : TranscriptState.fromJson(cache[transcript] as Map<String, dynamic>);
    final before = state.offset;
    state.readFrom(file);
    if (state.offset != before) {
      cache[transcript] = state.toJson();
      changed = true;
    } else {
      cache[transcript] ??= state.toJson();
    }
    sessions.add({
      'local_id': d['sessionId'],
      'title': d['title'],
      'title_source': d['titleSource'],
      'transcript': transcript,
      'prs': d['prs'],
    });
  }
  return {'cache': cache, 'sessions': sessions, 'changed': changed};
}

/// Where a desktop session record's transcript may be, most likely first.
/// Sessions run over SSH keep a local copy in `ssh-<id>/<id>.jsonl`, since
/// their `cwd` is a folder on the remote machine.
List<String> transcriptCandidates(Map<String, dynamic> record, String transcriptsDir, String os) {
  final cli = record['cliSessionId'] as String?;
  if (cli == null) return const [];
  final cwd = record['cwd'] as String?;
  final platform = ClaudePlatform.forOS(os, env: const {}, fileExists: (_) => false);
  return [
    if (record['sshConfig'] != null) p.join(transcriptsDir, 'ssh-$cli', '$cli.jsonl'),
    if (cwd != null)
      for (final folder in platform.transcriptFolderNames(cwd)) p.join(transcriptsDir, folder, '$cli.jsonl'),
    // A record without sshConfig can still have been an SSH session.
    if (record['sshConfig'] == null) p.join(transcriptsDir, 'ssh-$cli', '$cli.jsonl'),
  ];
}
