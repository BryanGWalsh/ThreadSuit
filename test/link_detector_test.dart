import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/services/claude_cli.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/link_detector.dart';
import 'package:thread_suit/services/link_service.dart';
import 'package:thread_suit/services/transcript_parser.dart';

String line(String type, Object content) => jsonEncode({
  'type': type,
  'timestamp': '2026-11-06T10:00:00Z',
  'message': {'content': content},
});

TranscriptState parse(List<String> lines) {
  final dir = Directory.systemTemp.createTempSync('t');
  final f = File('${dir.path}/t.jsonl')..writeAsStringSync('${lines.join('\n')}\n');
  final s = TranscriptState()..readFrom(f);
  dir.deleteSync(recursive: true);
  return s;
}

void main() {
  group('LinkDetector', () {
    test('finds URLs, without trailing punctuation, de-duplicated', () {
      expect(
        LinkDetector.findUrls('See https://a.example/x/1. And (https://b.example/y?q=1), https://a.example/x/1/ again'),
        ['https://a.example/x/1', 'https://b.example/y?q=1'],
      );
      expect(LinkDetector.findUrls('{"url":"https://c.example/z"}'), ['https://c.example/z']);
      expect(LinkDetector.findUrls('no links, ftp://x and https:// alone'), isEmpty);
    });

    test('finds ID-like references, not URLs or encodings', () {
      expect(LinkDetector.findRefs('Fixes acme/web#12 and #345, see OPS-7 (UTF-8, SHA-256) https://x.example/#99'), [
        'acme/web#12',
        '#345',
        'OPS-7',
      ]);
    });

    test('keeps only https links whose exact URL is in the evidence', () {
      const evidence =
          'URLs:\n- https://git.example/p/1\n- http://git.example/A-2\nTool result: see https://git.example/p/3';
      final links = [
        const ResolvedLink(kind: LinkKind.pullRequest, providerName: 'Git', key: '#1', url: 'https://git.example/p/1'),
        // Same host, but a URL nobody saw: made up.
        const ResolvedLink(kind: LinkKind.pullRequest, providerName: 'Git', key: '#2', url: 'https://git.example/p/2'),
        const ResolvedLink(kind: LinkKind.issue, providerName: 'X', key: 'A-1', url: 'https://made-up.example/A-1'),
        const ResolvedLink(kind: LinkKind.issue, providerName: 'X', key: 'A-2', url: 'http://git.example/A-2'),
        const ResolvedLink(
          kind: LinkKind.pullRequest,
          providerName: 'Git',
          key: '#1',
          url: 'https://www.git.example/p/1/',
        ),
        const ResolvedLink(kind: LinkKind.pullRequest, providerName: 'Git', key: '#3', url: 'https://git.example/p/3'),
      ];
      expect(LinkDetector.validate(links, evidence).map((l) => l.url), [
        'https://git.example/p/1',
        'https://git.example/p/3',
      ]);
    });

    test("names, keys, titles and states are taken as Haiku gives them; the URL is still checked", () {
      const evidence = 'Tool result: https://t.example/i/OPS-7';
      final out = LinkDetector.validate([
        const ResolvedLink(
          kind: LinkKind.issue,
          providerName: 'Jira',
          key: 'OPS-7',
          url: 'https://t.example/i/OPS-7',
          title: 'Fix login',
          state: 'Closed',
        ),
        const ResolvedLink(kind: LinkKind.issue, providerName: 'Jira', key: 'OPS-8', url: 'https://t.example/i/OPS-8'),
        const ResolvedLink(kind: LinkKind.issue, providerName: '', key: '', url: 'https://t.example/i/OPS-7?x=1'),
      ], evidence);
      expect(out.map((l) => (l.providerName, l.key, l.title, l.state)), [('Jira', 'OPS-7', 'Fix login', 'Closed')]);
      // Without a name or key, a link is labelled by host and path.
      final bare = LinkDetector.validate([
        const ResolvedLink(kind: LinkKind.other, providerName: '', key: '', url: 'https://t.example/i/OPS-7'),
      ], evidence).single;
      expect(bare.label, 't.example/i/OPS-7');
    });

    test('hash is stable and changes with the text', () {
      expect(LinkDetector.hash('abc'), LinkDetector.hash('abc'));
      expect(LinkDetector.hash('abc'), isNot(LinkDetector.hash('abd')));
      expect(LinkDetector.hash(''), 'cbf29ce484222325');
    });

    test('link text: provider, PR or MR for pull requests, key, then the title', () {
      ResolvedLink make(LinkKind kind, String provider, String key, {String? title, String? pr}) => ResolvedLink(
        kind: kind,
        providerName: provider,
        key: key,
        url: 'https://x.example/1',
        title: title,
        prWord: pr,
      );
      expect(make(LinkKind.pullRequest, 'GitHub', '#20', title: 'Fix login').text, 'GitHub PR #20: Fix login');
      expect(make(LinkKind.pullRequest, 'GitHub', '20').text, 'GitHub PR #20'); // numeric ids get a #
      expect(make(LinkKind.pullRequest, 'GitLab', '!7', pr: 'MR').text, 'GitLab MR !7');
      expect(make(LinkKind.issue, 'YouTrack', '#323', title: 'Issue title').text, 'YouTrack #323: Issue title');
      expect(make(LinkKind.issue, 'YouTrack', 'OPS-4').text, 'YouTrack OPS-4');
    });

    test("Haiku's label sets the provider's casing and PR or MR, never the title", () {
      final fromHaiku = ResolvedLink.fromJson({
        'kind': 'pull_request',
        'provider_name': 'gitlab',
        'key': '!7',
        'url': 'https://git.example/g/p/-/merge_requests/7',
        'label': 'GitLab MR !7: Cache build artifacts',
      })!;
      expect((fromHaiku.providerName, fromHaiku.prWord, fromHaiku.title), ('GitLab', 'MR', null));
      // A label with another provider name or an odd word changes nothing.
      final odd = ResolvedLink.fromJson({
        'kind': 'pull_request',
        'provider_name': 'GitHub',
        'key': '#3',
        'url': 'https://g.example/3',
        'label': 'Gitea Change #3',
      })!;
      expect((odd.providerName, odd.prWord, odd.label), ('GitHub', null, 'GitHub PR #3'));
    });

    test('a link whose URL nobody saw is dropped, whatever its title', () {
      const evidence = 'https://git.example/acme/web/pull/20 merged';
      final out = LinkDetector.validate([
        ResolvedLink.fromJson({
          'kind': 'pull_request',
          'provider_name': 'Git',
          'key': '#20',
          'url': 'https://git.example/acme/web/pull/20',
          'title': 'Cache build artifacts',
        })!,
        ResolvedLink.fromJson({
          'kind': 'pull_request',
          'provider_name': 'Git',
          'key': '#21',
          'url': 'https://git.example/acme/web/pull/21',
          'title': 'A PR nobody mentioned',
        })!,
      ], evidence);
      expect(out.map((l) => l.text), ['Git PR #20: Cache build artifacts']);
    });

    test('labels', () {
      expect(ResolvedLink.plain('https://www.docs.example/guide/start').label, 'docs.example/guide/start');
      // Not looked up yet: a pull request or issue path still reads as one.
      String plain(String url) => ResolvedLink.plain(url).text;
      expect(plain('https://github.com/acme/app/pull/1605'), 'github.com PR #1605');
      expect(plain('https://gitlab.example/g/p/-/merge_requests/3'), 'gitlab.example MR !3');
      expect(plain('https://git.example/a/b/issues/41'), 'git.example #41');
      expect(
        plain('https://linear.app/acme/issue/MOB-47/shipped-alerts-survive-a-failed-queue-write'),
        'linear.app MOB-47: Shipped alerts survive a failed queue write',
      );
      expect(plain('https://tracker.example/browse/OPS-7'), 'tracker.example OPS-7');
      expect(ResolvedLink.plain('https://github.com/acme/app/pull/1605').kind, LinkKind.pullRequest);
      final l = ResolvedLink.fromJson({
        'kind': 'pull_request',
        'provider_name': 'GitHub',
        'key': '#12',
        'url': 'https://github.com/a/b/pull/12',
        'title': ' Fix login ',
        'state': '',
      })!;
      expect((l.kind, l.label, l.title, l.state), (LinkKind.pullRequest, 'GitHub PR #12', 'Fix login', null));
      expect(ResolvedLink.fromJson(ResolvedLink.fromJson(l.toJson())!.toJson())!.kind, LinkKind.pullRequest);
      expect(ResolvedLink.fromJson({'title': 'no url'}), isNull);
    });
  });

  group('Haiku link lookups', () {
    test('only read-only MCP and plugin tools, and commands the threads ran, are allowed', () {
      final tools = ClaudeCli.linkLookupTools(
        ['mcp__youtrack__get_issue', 'mcp__youtrack__update_issue', 'mcp__plugin_x_y__list_tasks', 'Bash'],
        ['Bash(gh pr view *)', 'Bash(rm -rf *)x'],
      );
      expect(tools, ['mcp__plugin_x_y__list_tasks', 'mcp__youtrack__get_issue', 'Bash(gh pr view *)']);
    });

    test('reads the JSON array out of the answer', () {
      expect(ClaudeCli.parseLinkAnswer('```json\n[{"url":"https://a.example"}]\n```'), [
        {'url': 'https://a.example'},
      ]);
      expect(ClaudeCli.parseLinkAnswer('[]'), isEmpty);
      expect(ClaudeCli.parseLinkAnswer('sorry'), isNull);
    });
  });

  group('transcript', () {
    test('collects URLs, calls and references from messages and tools, not from files', () {
      Map use(String id, String name, Map input) => {'type': 'tool_use', 'id': id, 'name': name, 'input': input};
      Map result(String id, String out) => {'type': 'tool_result', 'tool_use_id': id, 'content': out};
      final s = parse([
        line('user', 'Please look at https://tracker.example/browse/OPS-7 and acme/web#12'),
        line('assistant', [
          use('m1', 'mcp__tracker__get_issue', {'key': 'OPS-7'}),
          use('p1', 'mcp__plugin_git_git__view_pull_request', {'url': 'https://git.example/acme/web/pull/12'}),
          use('b1', 'Bash', {'command': 'cd api && gh pr view 12 --json url'}),
          use('b2', 'Bash', {'command': 'cat notes.md'}),
          use('b3', 'Bash', {'command': "python3 - <<'EOF'\nprint('https://fake.example/1')\nEOF"}),
          use('w1', 'Write', {'content': 'https://fake.example/2'}),
          use('g1', 'Bash', {'command': 'git diff'}),
          use('k1', 'Bash', {'command': 'gh pr list | while read n; do gh pr view \$n; done'}),
          use('k2', 'Bash', {'command': 'for f in *; do python3 drive.py get \$f; done'}),
        ]),
        line('user', [
          result('m1', 'Title: Fix login. https://tracker.example/browse/OPS-7'),
          result('p1', 'merged'),
          result('b1', '{"url":"https://git.example/acme/web/pull/12"}'),
          result('b2', 'https://fake.example/3'),
          result('b3', 'https://fake.example/1'),
          result('w1', 'ok'),
          result('g1', '+ https://fake.example/4'),
        ]),
      ]);
      // Newest last: the issue URL came again in the tool result.
      expect(s.urls, ['https://git.example/acme/web/pull/12', 'https://tracker.example/browse/OPS-7']);
      expect(s.shellUrls, ['https://git.example/acme/web/pull/12']);
      expect(s.refs, ['acme/web#12']); // OPS-7 is only inside a URL
      expect(s.toolNames, {'mcp__tracker__get_issue', 'mcp__plugin_git_git__view_pull_request'});
      // Never a rule for a keyword or loop (`while read *`, `do ... *`).
      expect(s.readCommands, {'Bash(gh pr view *)', 'Bash(gh pr list *)'});
      expect(s.toolCalls, [
        'mcp__tracker__get_issue {"key":"OPS-7"}',
        'mcp__plugin_git_git__view_pull_request {"url":"https://git.example/acme/web/pull/12"}',
        r'$ gh pr view 12 --json url',
        r'$ gh pr list',
        r'$ gh pr view $n',
      ]);

      final back = TranscriptState.fromJson(s.toJson());
      expect(back.urls, s.urls);
      expect(back.shellUrls, s.shellUrls);
      expect(back.refs, s.refs);
      expect(back.toolCalls, s.toolCalls);
      expect(back.readCommands, s.readCommands);
      expect(TranscriptState.fromJson({'offset': 99, 'messages': []}).offset, 0); // old cache: re-read
    });

    test('shell lines are split respecting quotes; pipelines with local commands are not link sources', () {
      expect(TranscriptState.splitShell('flutter test 2>&1 | grep -E "Expected|Actual|Which" | head -5'), [
        ['flutter', 'test', '2>&1'],
        ['grep', '-E', 'Expected|Actual|Which'],
        ['head', '-5'],
      ]);
      expect(TranscriptState.splitShell("cd a && gh pr view 1 --json url; echo 'x;y'"), [
        ['cd', 'a'],
        ['gh', 'pr', 'view', '1', '--json', 'url'],
        ['echo', 'x;y'],
      ]);
      expect(TranscriptState.splitShell("python3 - <<'EOF'\nprint('https://x.example')\nEOF"), [
        ['python3', '-'],
      ]);

      Map use(String id, String cmd) => {
        'type': 'tool_use',
        'id': id,
        'name': 'Bash',
        'input': {'command': cmd},
      };
      Map result(String id, String out) => {'type': 'tool_result', 'tool_use_id': id, 'content': out};
      final s = parse([
        line('assistant', [
          use('a', 'flutter test 2>&1 | grep -E "Expected|Actual|Which"'),
          use('b', 'gh pr list 2>&1 | head -3'),
          use('c', 'gh pr view 4 --json url'),
        ]),
        line('user', [
          result('a', "Expected: ['https://git.example/acme/web/pull/12', 'https://tracker.example/browse/OPS-7']"),
          result('b', 'https://git.example/real/pull/3'),
          result('c', 'https://git.example/real/pull/4'),
        ]),
      ]);
      // Test output never counts; `| head` makes a remote command's output local.
      expect(s.shellUrls, ['https://git.example/real/pull/4']);
      expect(s.toolCalls, [r'$ gh pr view 4 --json url']);
      // The rules are still learned from the piped command.
      expect(s.readCommands, {'Bash(gh pr list *)', 'Bash(gh pr view *)'});
    });

    test('Remote Control project sessions: replies sent with send_message are Claude messages', () {
      Map send(String id, String visibility, String text) => {
        'type': 'tool_use',
        'id': id,
        'name': 'mcp__claude-code-remote__send_message',
        'input': {'session_id': '@parent', 'visibility': visibility, 'message': text},
      };
      final s = parse([
        line(
          'user',
          '<wake reason="mention"><project id="chan_P" type="project"><thread ts="cmsg_T">'
              '<message trigger="true" from="human" trust="principal" author-id="u1" id="cmsg_M1" '
              'sent-at="2026-11-06T10:00:00Z">can you fix it?</message></thread></project></wake>',
        ),
        line('assistant', [send('t1', 'posted_to_shared_channel', 'Fixed it.')]),
        line('assistant', [send('t2', 'sent_to_shared_agent', 'coordination note')]),
      ]);
      expect(s.isProjectThread, isTrue);
      expect(s.threadId, 'cmsg_T');
      expect(s.messages.map((m) => (m.fromHuman, m.text)), [(true, 'can you fix it?'), (false, 'Fixed it.')]);
      // The Remote Control report is this computer's notes, not the thread's reply.
      expect(s.messages.map((m) => m.kind), ['reply', 'notes']);
      expect(TranscriptState.fromJson(s.toJson()).messages.last.kind, 'notes');
      expect(s.toolNames, isEmpty); // the reply tool isn't a link source
    });
  });

  group('LinkService', () {
    late DataDir dir;
    late DateTime clock;
    late _FakeCli cli;
    LinkService make({bool enabled = true}) => LinkService(
      dir,
      cli,
      enabled: enabled,
      debounce: const Duration(seconds: 30),
      minInterval: const Duration(minutes: 1),
      now: () => clock,
    );

    final digest = LinkDigest(
      urls: ['https://tracker.example/browse/OPS-7', 'https://docs.example/guide'],
      toolCalls: ['mcp__tracker__get_issue {"key":"OPS-7"}'],
      refs: ['OPS-7'],
    );

    setUp(() {
      dir = DataDir.at(Directory.systemTemp.createTempSync('links').path);
      clock = DateTime(2026, 11, 6, 12);
      cli = _FakeCli([
        {
          'kind': 'issue',
          'provider_name': 'Tracker',
          'key': 'OPS-7',
          'title': 'Fix login',
          'state': 'open',
          'url': 'https://tracker.example/browse/OPS-7',
        },
        {'kind': 'issue', 'provider_name': 'Made up', 'key': 'X-1', 'url': 'https://invented.example/X-1'},
      ], toolResults: '{"project": "Tracker", "summary": "Fix login", "status": "open"}');
    });

    test('fabricated items are dropped: a made-up repo and tracker for a thread without either', () async {
      // The thread only has a docs link and ran a local build.
      final plain = LinkDigest(urls: ['https://docs.example/guide'], toolCalls: [r'$ gh auth status']);
      cli = _FakeCli([
        {'kind': 'pull_request', 'provider_name': 'GitHub', 'key': '#12', 'url': 'https://github.com/acme/web/pull/12'},
        {'kind': 'issue', 'provider_name': 'Jira', 'key': 'OPS-7', 'url': 'https://acme.atlassian.net/browse/OPS-7'},
      ]);
      final svc = make();
      svc.linksFor('t1', plain);
      clock = clock.add(const Duration(seconds: 31));
      await svc.resolveNow();
      expect(cli.calls, 1);
      expect(svc.linksFor('t1', plain), isEmpty); // looked up, nothing real: no links
      await svc.dispose();
    });

    test('no evidence (only references, or only local URLs): no call at all', () async {
      final svc = make();
      for (final d in [
        LinkDigest(refs: ['#123', 'ABC-12']),
        LinkDigest(urls: ['http://127.0.0.1:47321/changed', 'http://localhost:3000/x'], refs: ['#5']),
      ]) {
        expect(d.hasEvidence, isFalse);
        svc.linksFor('t-${d.hash}', d);
      }
      clock = clock.add(const Duration(minutes: 5));
      await svc.resolveNow();
      expect(cli.calls, 0);
      await svc.dispose();
    });

    test('plain URLs first; one debounced, rate-limited, cached lookup; made-up hosts dropped', () async {
      final svc = make()..knownTools = {'mcp__tracker__get_issue', 'mcp__tracker__delete_issue'};
      expect(svc.linksFor('t1', digest).map((l) => l.label), ['docs.example/guide', 'tracker.example OPS-7']);

      await svc.resolveNow(); // still settling
      expect(cli.calls, 0);
      clock = clock.add(const Duration(seconds: 31));
      await svc.resolveNow();
      expect(cli.calls, 1);
      expect(cli.lastDigest, contains('mcp__tracker__get_issue'));
      expect(cli.lastTools, ['mcp__tracker__get_issue']);

      final links = svc.linksFor('t1', digest);
      expect(links.map((l) => (l.label, l.title)), [('Tracker OPS-7', 'Fix login')]);

      // Same digest: cached, no second call, even after restarting.
      clock = clock.add(const Duration(minutes: 5));
      final again = make();
      again.linksFor('t1', digest);
      await again.resolveNow();
      expect(cli.calls, 1);
      expect(again.linksFor('t1', digest).single.title, 'Fix login');

      // A changed digest is looked up again, but not within 10 minutes of the
      // last lookup of that thread.
      final changed = LinkDigest(urls: [...digest.urls, 'https://tracker.example/browse/OPS-8']);
      again.linksFor('t1', changed);
      clock = clock.add(const Duration(seconds: 31));
      await again.resolveNow();
      expect(cli.calls, 1);
      clock = clock.add(const Duration(minutes: 5));
      await again.resolveNow();
      expect(cli.calls, 2);
      await svc.dispose();
      await again.dispose();
    });

    test('threads open as tiles are looked up first, with a shorter wait', () async {
      final svc = make();
      final other = LinkDigest(urls: ['https://docs.example/other'], toolCalls: const [], refs: const []);
      svc.linksFor('waiting', digest);
      clock = clock.add(const Duration(seconds: 5));
      svc.linksFor('open', LinkDigest(urls: digest.urls, toolCalls: digest.toolCalls, refs: const ['OPS-8']));
      svc.priority = {'open'};
      clock = clock.add(const Duration(seconds: 31));
      await svc.resolveNow();
      expect(cli.calls, 1);
      expect(cli.lastDigest, contains('OPS-8')); // the open thread, though it queued later
      // The next open thread needs only the short wait, not the minute.
      svc.linksFor('open2', other);
      svc.priority = {'open', 'open2'};
      clock = clock.add(const Duration(seconds: 31));
      await svc.resolveNow();
      expect(cli.calls, 2);
      await svc.dispose();
    });

    test('a failed lookup is cached and falls back to plain URLs', () async {
      cli.fail = true;
      final svc = make();
      svc.linksFor('t1', digest);
      clock = clock.add(const Duration(seconds: 31));
      await svc.resolveNow();
      clock = clock.add(const Duration(minutes: 5));
      svc.linksFor('t1', digest);
      await svc.resolveNow();
      expect(cli.calls, 1);
      // The plain fallback still reads an issue-shaped path as an issue.
      expect(svc.linksFor('t1', digest).map((l) => l.kind), [LinkKind.other, LinkKind.issue]);
      await svc.dispose();
    });

    test('turned off: plain URLs only, never a call', () async {
      final svc = make(enabled: false);
      svc.linksFor('t1', digest);
      clock = clock.add(const Duration(minutes: 5));
      await svc.resolveNow();
      expect(cli.calls, 0);
      expect(svc.linksFor('t1', digest), hasLength(2));
      File(dir.config).writeAsStringSync('{"resolve_links": false}');
      expect(LinkService.readEnabled(dir), isFalse);
      File(dir.config).writeAsStringSync('{}');
      expect(LinkService.readEnabled(dir), isTrue);
      await svc.dispose();
    });

    test('ordinary shell commands do not trigger a new lookup', () {
      final a = LinkDigest(urls: ['https://x.example/1'], toolCalls: [r'$ git status']);
      final b = LinkDigest(urls: ['https://x.example/1'], toolCalls: [r'$ git status', r'$ flutter test']);
      final c = LinkDigest(urls: ['https://x.example/1'], toolCalls: ['mcp__t__get_issue {"id":1}']);
      expect(a.hash, b.hash);
      expect(a.hash, isNot(c.hash));
      expect(b.text, contains('flutter test'));
    });

    test('plain URLs skip this computer, the local network, assets and bare hosts', () {
      final d = LinkDigest(
        urls: [
          'http://127.0.0.1:47321/changed',
          'http://localhost:3000/app',
          'http://192.168.1.5/admin',
          'https://cdn.example/logo.png',
          'https://example.com/',
          'https://tracker.example/issue/A-1',
        ],
      );
      expect(d.plainUrls, ['https://tracker.example/issue/A-1']);
    });

    test('nothing to look up: no call', () async {
      final svc = make();
      expect(svc.linksFor('t1', LinkDigest()), isEmpty);
      clock = clock.add(const Duration(minutes: 5));
      await svc.resolveNow();
      expect(cli.calls, 0);
      await svc.dispose();
    });
  });
}

class _FakeCli extends ClaudeCli {
  final List<Map> answer;
  bool fail = false;
  int calls = 0;
  String lastDigest = '';
  List<String> lastTools = [];
  final String toolResults;
  _FakeCli(this.answer, {this.toolResults = ''});

  @override
  Future<({List<Map> items, String toolResults})?> resolveLinks(String digest, List<String> allowedTools) async {
    calls++;
    lastDigest = digest;
    lastTools = allowedTools;
    return fail ? null : (items: answer, toolResults: toolResults);
  }
}
