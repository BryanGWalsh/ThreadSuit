/// Generic link finding: no provider is known or assumed. A thread's URLs,
/// tool calls and ID-like references are collected as they are; Haiku, with
/// the user's own MCP, plugin and CLI tools, turns them into PR and issue
/// links ([ResolvedLink]). See docs/FILE_FORMAT.md, "Links".
library;

/// What a link points at; only the icon depends on it.
enum LinkKind {
  pullRequest,
  issue,
  other;

  static LinkKind parse(Object? s) => switch (s) {
    'pull_request' || 'pullRequest' || 'pr' || 'merge_request' => LinkKind.pullRequest,
    'issue' || 'ticket' || 'task' || 'story' || 'bug' => LinkKind.issue,
    _ => LinkKind.other,
  };
}

/// A link for one thread, as Haiku returned it, or a plain URL (fallback).
class ResolvedLink {
  final LinkKind kind;

  /// The tool it lives in, as Haiku named it ("GitHub", "Jira"...); for a
  /// plain URL, its host.
  final String providerName;

  /// The item's id within its tool ("#12", "OPS-7"); for a plain URL, its path.
  final String key;
  final String url;
  final String? title;
  final String? state;

  /// What the provider calls a pull request ("PR" or "MR"); null for others.
  final String? prWord;

  const ResolvedLink({
    required this.kind,
    required this.providerName,
    required this.key,
    required this.url,
    this.title,
    this.state,
    this.prWord,
  });

  /// A URL with nothing known about it: labelled by host and path.
  factory ResolvedLink.plain(String url) {
    final u = Uri.tryParse(url);
    final path = (u?.path ?? '').replaceAll(RegExp(r'/+$'), '');
    return ResolvedLink(
      kind: LinkKind.other,
      providerName: LinkDetector.hostOf(url) ?? url,
      key: path.length > 40 ? '…${path.substring(path.length - 39)}' : path,
      url: url,
    );
  }

  /// "GitHub #12", "Jira OPS-7"; for a plain URL, "example.com/a/b".
  /// "GitHub PR #20", "GitLab MR !3", "YouTrack OPS-4", "Jira #323"; for a
  /// plain URL, "example.com/a/b". The title, if any, follows after ": ".
  String get label {
    if (key.isEmpty) return providerName;
    if (key.startsWith('/') || key.startsWith('…')) return '$providerName$key';
    final id = RegExp(r'^\d+$').hasMatch(key) ? '#$key' : key;
    return kind == LinkKind.pullRequest ? '$providerName ${prWord ?? 'PR'} $id' : '$providerName $id';
  }

  /// The full link text: "GitHub PR #20: Fix login".
  String get text => title == null ? label : '$label: $title';

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'provider_name': providerName,
    'key': key,
    'url': url,
    if (title != null) 'title': title,
    if (state != null) 'state': state,
    if (prWord != null) 'pr_word': prWord,
  };

  /// Reads both the cache format and Haiku's answer (`"pull_request"`...).
  static ResolvedLink? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return ResolvedLink(
      kind: LinkKind.parse(j['kind']),
      providerName:
          _cased(str(j['provider_name']), _labelPart(j['label'], 1)) ?? LinkDetector.hostOf(j['url'] as String) ?? '',
      key: str(j['key']) ?? '',
      url: (j['url'] as String).trim(),
      title: str(j['title']),
      state: str(j['state']),
      prWord: switch (str(j['pr_word']) ?? _labelPart(j['label'], 2)) {
        final w? when w == 'PR' || w == 'MR' => w,
        _ => null,
      },
    );
  }

  // Haiku's "label" ("GitHub PR #20: Fix login"): provider, PR/MR word, key.
  static final _labelShape = RegExp(r'^\s*(.*?)\s+(?:(PR|MR)\s+)?([#!]?[\w.-]*\d[\w.-]*)\s*(?::|$)');

  static String? _labelPart(Object? label, int group) {
    if (label is! String) return null;
    final m = _labelShape.firstMatch(label);
    final s = m?[group]?.trim();
    return s == null || s.isEmpty ? null : s;
  }

  /// The provider name as the label spells it ("GitHub" for "github"), when
  /// the two agree; otherwise [name] as given.
  static String? _cased(String? name, String? fromLabel) {
    if (name == null) return fromLabel;
    if (fromLabel != null && fromLabel.toLowerCase() == name.toLowerCase()) return fromLabel;
    return name;
  }

  @override
  bool operator ==(Object other) => other is ResolvedLink && LinkDetector.sameUrl(other.url, url);

  @override
  int get hashCode => LinkDetector.normalize(url).hashCode;

  @override
  String toString() => 'ResolvedLink($providerName $key, $url)';
}

class LinkDetector {
  static final _url = RegExp(r'''https?://[^\s"'<>()\[\]{}`|\\]+''');
  static final _trailing = RegExp(r'[.,;:!?*_~]+$');

  /// Every http(s) URL in [text], in order, de-duplicated, without trailing
  /// punctuation.
  static List<String> findUrls(String text) {
    if (!text.contains('://')) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final m in _url.allMatches(text)) {
      final u = m[0]!.replaceAll(_trailing, '');
      if (hostOf(u) == null) continue;
      if (seen.add(normalize(u))) out.add(u);
    }
    return out;
  }

  // ID-like tokens: owner/repo#12, #123, ABC-12. Generic shapes, not tools.
  static final _repoRef = RegExp(r'\b[\w.-]+/[\w.-]+#\d{1,6}\b');
  static final _hashRef = RegExp(r'(?<![\w/#&])#\d{2,6}\b');
  static final _keyRef = RegExp(r'\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b');
  static final _notRef = RegExp(r'^(UTF|SHA|ISO|RFC|HTTP|TLS|SSL|AES|RSA|ES|GPT|MD|COVID|IPV|CVE|PEP)\d*-');

  /// Bare references in [text] that may name a PR or issue. URLs are skipped.
  static List<String> findRefs(String text) {
    final t = text.replaceAll(_url, ' ');
    final out = <String>{};
    for (final m in _repoRef.allMatches(t)) {
      out.add(m[0]!);
    }
    for (final m in _hashRef.allMatches(t.replaceAll(_repoRef, ' '))) {
      out.add(m[0]!);
    }
    for (final m in _keyRef.allMatches(t)) {
      if (!_notRef.hasMatch(m[0]!)) out.add(m[0]!);
    }
    return out.toList();
  }

  /// For comparing URLs: no scheme, `www.`, trailing slash, query or fragment.
  static String normalize(String url) => url
      .replaceFirst(RegExp(r'^https?://(www\.)?'), '')
      .replaceFirst(RegExp(r'[?#].*$'), '')
      .replaceFirst(RegExp(r'/+$'), '')
      .toLowerCase();

  static bool sameUrl(String a, String b) => normalize(a) == normalize(b);

  static String? hostOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !u.hasScheme || u.host.isEmpty) return null;
    return u.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  }

  /// Keeps only what Haiku could not have made up. [evidence] is everything
  /// it was shown or found: the thread's digest and the text of its own tool
  /// results. A link survives only if it's `https` and its exact URL appears
  /// in [evidence] (compared without scheme, `www.`, trailing slash, query or
  /// fragment). Its title, state, provider name and key are kept only if they
  /// appear in [evidence] too; otherwise the link is labelled by its host
  /// and path. Duplicates are dropped.
  static List<ResolvedLink> validate(Iterable<ResolvedLink> links, String evidence) {
    final urls = {for (final u in findUrls(evidence)) normalize(u)};
    final text = _squash(evidence);
    bool seen(String? s) => s != null && s.trim().isNotEmpty && text.contains(_squash(s));
    final out = <ResolvedLink>[];
    for (final l in links) {
      if (Uri.tryParse(l.url)?.scheme != 'https' || !urls.contains(normalize(l.url))) continue;
      final plain = ResolvedLink.plain(l.url);
      // A key counts if the evidence shows it, or the URL itself carries its
      // id ("#7" for ".../pull/7", "OPS-7" for ".../browse/OPS-7").
      final keyOk = seen(l.key) || _inUrl(l.key, l.url);
      final checked = ResolvedLink(
        kind: l.kind,
        providerName: keyOk && seen(l.providerName) ? l.providerName : plain.providerName,
        key: keyOk ? l.key : plain.key,
        url: l.url,
        title: seen(l.title) ? l.title : null,
        state: seen(l.state) ? l.state : null,
        prWord: l.prWord,
      );
      if (!out.contains(checked)) out.add(checked);
    }
    return out;
  }

  static bool _inUrl(String key, String url) {
    final id = key.replaceFirst(RegExp(r'^[#!]'), '').toLowerCase();
    if (id.isEmpty) return false;
    final segments = (Uri.tryParse(url)?.pathSegments ?? const []).map((s) => s.toLowerCase());
    return segments.contains(id);
  }

  static String _squash(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// A stable 64-bit FNV-1a hash, as hex (Dart's own hashCode isn't stable
  /// across runs).
  static String hash(String s) {
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final c in s.codeUnits) {
      h = ((h ^ BigInt.from(c)) * prime) & mask;
    }
    return h.toRadixString(16);
  }
}
