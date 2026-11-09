import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import '../platform/claude_platform.dart';
import 'claude_cli.dart';
import 'data_dir.dart';
import 'link_detector.dart';

/// What one thread touched, for finding its PRs and issues: the URLs, tool
/// calls and references its transcripts collected (see `TranscriptState`).
class LinkDigest {
  final List<String> urls;
  final List<String> shellUrls;
  final List<String> toolCalls;
  final List<String> refs;

  /// What the thread is about: its title and the request that started it.
  final List<String> focus;

  LinkDigest({
    this.urls = const [],
    this.shellUrls = const [],
    this.toolCalls = const [],
    this.refs = const [],
    this.focus = const [],
  });

  /// How strongly the thread is about [url]: 2 when its title or opening
  /// request names it, 2 more when a tool call acted on it, 0 when it's only
  /// mentioned in passing (an example, another thread's work). Matches the
  /// URL itself or, for PR and issue URLs, their key ("#1605", "MOB-47").
  int relevance(String url) {
    final tokens = _tokens(url);
    bool any(String text) => tokens.any((t) => t.hasMatch(text));
    final focusText = focus.join('\n');
    final callText = toolCalls.join('\n');
    return (any(focusText) ? 2 : 0) + (any(callText) ? 2 : 0);
  }

  static List<RegExp> _tokens(String url) {
    final out = [RegExp(RegExp.escape(url.replaceAll(RegExp(r'/+$'), '')))];
    final path = Uri.tryParse(url)?.path ?? '';
    if (RegExp(r'/(?:pull|pulls|merge_requests|issues)/(\d+)').firstMatch(path) case final m?) {
      // "#1605", "PR 1605", "pull/1605", and a bare 1605 as a command argument.
      out.add(RegExp('(?:#|!|\\bPR\\s*#?|\\bMR\\s*!?|pull/|issues/|(?<=\\s))${m[1]}\\b', caseSensitive: false));
    }
    if (RegExp(r'/(?:issue|issues|browse)/([A-Z][A-Z0-9]*-\d+)').firstMatch(path) case final m?) {
      out.add(RegExp('\\b${m[1]}\\b'));
    }
    return out;
  }

  bool get isEmpty => urls.isEmpty && shellUrls.isEmpty && toolCalls.isEmpty && refs.isEmpty;

  /// Whether a lookup could find anything: a URL that isn't on this computer
  /// or the local network, or a connector, plugin or CLI call. References
  /// alone (`#12`, `ABC-12`) aren't enough: with nothing to look them up in,
  /// any link would be made up.
  bool get hasEvidence =>
      [...urls, ...shellUrls].any((u) => !_localHost.hasMatch(Uri.tryParse(u)?.host ?? 'localhost')) ||
      toolCalls.isNotEmpty;

  /// Everything a returned link may be checked against: the full lists, not
  /// just the (possibly shortened) [text].
  String get evidence => [text, ...urls, ...shellUrls].join('\n');

  /// About 4k tokens at most.
  static const maxChars = 12000;

  /// The summary Haiku reads. Newest items last, oldest dropped if too long.
  String get text {
    String section(String title, List<String> items) =>
        items.isEmpty ? '' : '$title:\n${items.map((i) => '- $i').join('\n')}\n';
    var u = urls, s = shellUrls, c = toolCalls, r = refs;
    String build() => [
      section('What the thread is about (title and opening request)', focus.map(_short).toList()),
      section('URLs in messages and connector tools', u),
      section('URLs in command output', s),
      section('Tool calls', c),
      section('References in messages', r),
    ].join();
    var out = build();
    while (out.length > maxChars && (u.length + s.length + c.length + r.length) > 4) {
      List<String> trim(List<String> l) => l.length > 1 ? l.sublist(l.length ~/ 4 + 1) : l;
      u = trim(u);
      s = trim(s);
      c = trim(c);
      r = trim(r);
      out = build();
    }
    return out.length > maxChars ? out.substring(out.length - maxChars) : out;
  }

  /// Changes only when something that can change the answer changes: URLs,
  /// references and connector calls. Ordinary shell commands (`git status`,
  /// builds) are in [text] for context but don't trigger a new lookup.
  String get hash => LinkDetector.hash(
    [...urls, '|', ...shellUrls, '|', ...refs, '|', ...toolCalls.where((c) => c.startsWith('mcp__'))].join('\n'),
  );

  static String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 600 ? '${one.substring(0, 600)}…' : one;
  }

  static final _localHost = RegExp(
    r'^(localhost|127\.\d+\.\d+\.\d+|0\.0\.0\.0|\[::1\]|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$|\.local$|\.localhost$',
  );
  static final _assetPath = RegExp(r'\.(png|jpe?g|gif|svg|ico|webp|css|js|map|woff2?|ttf)$', caseSensitive: false);

  /// URLs worth showing as plain links when there's no lookup result: not
  /// this computer or the local network, not images or web assets, and not
  /// a bare host. When some are clearly what the thread is about
  /// ([relevance]), passing mentions are left out. Most relevant first, then
  /// newest.
  List<String> get plainUrls {
    final candidates = [
      for (final u in urls.reversed)
        if (Uri.tryParse(u) case final uri?
            when !_localHost.hasMatch(uri.host) &&
                !_assetPath.hasMatch(uri.path) &&
                uri.path.replaceAll('/', '').isNotEmpty)
          u,
    ];
    final scores = {for (final u in candidates) u: relevance(u)};
    final keep = scores.values.any((v) => v > 0) ? candidates.where((u) => scores[u]! > 0).toList() : candidates;
    // Stable sort: equal scores keep newest-first order.
    final indexed = keep.indexed.toList()
      ..sort((a, b) {
        final byScore = scores[b.$2]!.compareTo(scores[a.$2]!);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return [for (final (_, u) in indexed) u];
  }
}

/// Finds the PRs and issues each thread is about, with no provider-specific
/// code. Haiku reads the thread's [LinkDigest] and may use the user's own
/// read-only MCP, plugin and CLI tools to fill in titles and states
/// ([ClaudeCli.resolveLinks]). Every link it returns must be `https` on a host
/// the thread already mentions, so it can't make one up.
///
/// Token use stays small: a thread is looked up only when its digest changed
/// ([LinkDigest.hash]) and then stayed the same for [debounce], one thread at
/// a time, at most once per [minInterval] overall and [perThreadInterval] per
/// thread. Results and failures are cached per thread and digest in
/// `links.json`, so nothing is asked twice.
///
/// Without a lookup (turned off, `claude` missing, or not done yet) a thread
/// shows the plain URLs from its messages and connector tools instead.
class LinkService implements InjectableWithDisposeInterface {
  /// `resolve_links` in `config.json` (default true), or
  /// THREAD_SUIT_RESOLVE_LINKS=0 to turn lookups off.
  static bool readEnabled(DataDir dir) {
    final env = ClaudePlatform.current.env['THREAD_SUIT_RESOLVE_LINKS'];
    if (env != null) return !{'0', 'false', 'off', 'no'}.contains(env.toLowerCase());
    try {
      final config = jsonDecode(File(dir.config).readAsStringSync()) as Map<String, dynamic>;
      return config['resolve_links'] != false;
    } catch (_) {
      return true;
    }
  }

  /// Bumped when lookups change; older cached results are dropped.
  static const cacheVersion = 6;

  final DataDir _dir;
  final ClaudeCli _cli;
  final bool enabled;
  final Duration debounce;
  final Duration minInterval;

  /// The least time between two lookups of the same thread.
  final Duration perThreadInterval;

  /// The least time between lookups while a thread in [priority] is waiting.
  final Duration priorityInterval;

  /// Threads open as tiles: their lookups go first and wait less.
  Set<String> priority = {};
  final DateTime Function() _now;

  final _changes = PublishSubject<void>();
  late Map<String, dynamic> _cache; // thread id -> {hash, links} or {hash, failed: true}
  final _pending = <String, (LinkDigest, String hash, DateTime since)>{};
  bool _working = false;
  DateTime? _lastCall;
  Timer? _timer;

  /// MCP and plugin tool names, and read-only shell command rules, seen in
  /// this computer's sessions; set by [LocalThreadsService] after each scan.
  Set<String> knownTools = {};
  Set<String> readCommands = {};

  Stream<void> get changes => _changes.stream;

  LinkService(
    this._dir,
    this._cli, {
    bool? enabled,
    this.debounce = const Duration(seconds: 30),
    this.minInterval = const Duration(minutes: 1),
    this.perThreadInterval = const Duration(minutes: 10),
    this.priorityInterval = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : enabled = enabled ?? readEnabled(_dir),
       _now = now ?? DateTime.now {
    try {
      _cache = jsonDecode(File(_dir.links).readAsStringSync()) as Map<String, dynamic>;
      if (_cache['_v'] != cacheVersion) _cache = {'_v': cacheVersion};
    } catch (_) {
      _cache = {'_v': cacheVersion};
    }
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _resolve());
  }

  /// The links to show for [threadId]: the last lookup's result if there is
  /// one, otherwise plain URLs. Queues a lookup when the digest changed.
  List<ThreadLink> linksFor(String threadId, LinkDigest digest) {
    final cached = _cache[threadId] as Map?;
    final hash = digest.hash;
    if (enabled && digest.hasEvidence && cached?['hash'] != hash) {
      final p = _pending[threadId];
      if (p == null || p.$2 != hash) _pending[threadId] = (digest, hash, _now());
    }
    final resolved = cached?['links'];
    if (resolved is List) {
      return [for (final l in resolved) ?ResolvedLink.fromJson(l)];
    }
    // Not looked up (yet), or it failed: plain URLs, newest first.
    return {for (final u in digest.plainUrls) ResolvedLink.plain(u)}.take(10).toList();
  }

  /// Runs one lookup pass now, instead of waiting for the timer (for tests).
  @visibleForTesting
  Future<void> resolveNow() => _resolve();

  Future<void> _resolve() async {
    if (_working || _pending.isEmpty) return;
    final now = _now();
    // Open threads first; then the thread whose digest has been still the
    // longest, once it's settled.
    final ready = _pending.entries.where((e) {
      if (now.difference(e.value.$3) < debounce) return false;
      final at = DateTime.tryParse(((_cache[e.key] as Map?)?['at'] as String?) ?? '');
      return at == null || now.difference(at) >= perThreadInterval;
    }).toList()..sort((a, b) {
      final pa = priority.contains(a.key), pb = priority.contains(b.key);
      return pa != pb ? (pa ? -1 : 1) : a.value.$3.compareTo(b.value.$3);
    });
    if (ready.isEmpty) return;
    final gap = priority.contains(ready.first.key) ? priorityInterval : minInterval;
    if (_lastCall != null && now.difference(_lastCall!) < gap) return;
    final MapEntry(key: threadId, value: (digest, hash, _)) = ready.first;
    _working = true;
    _lastCall = now;
    try {
      final run = await _cli.resolveLinks(digest.text, ClaudeCli.linkLookupTools(knownTools, readCommands));
      // Only what the thread or Haiku's own tool results show survives.
      final links = run == null
          ? null
          : LinkDetector.validate(
              run.items.map(ResolvedLink.fromJson).nonNulls,
              '${digest.evidence}\n${run.toolResults}',
            );
      _cache[threadId] = {
        'hash': hash,
        if (links == null) 'failed': true else 'links': links.map((l) => l.toJson()).toList(),
        'at': now.toUtc().toIso8601String(),
        if (_cli.lastUsage?.usd != null) 'cost_usd': _cli.lastUsage!.usd,
      };
      if (_pending[threadId]?.$2 == hash) _pending.remove(threadId);
      final tmp = File('${_dir.links}.tmp')..writeAsStringSync(jsonEncode(_cache));
      tmp.renameSync(_dir.links);
      _changes.add(null);
    } catch (_) {
      // Try again on a later tick.
    } finally {
      _working = false;
    }
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _changes.close();
  }
}
