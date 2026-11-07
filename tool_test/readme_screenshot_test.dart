// Renders the README screenshots from made-up threads only: a fake home
// folder with fictional Claude sessions, so nothing real can leak.
//   flutter test tool_test/readme_screenshot_test.dart
//   THEME=dark flutter test tool_test/readme_screenshot_test.dart
// Writes docs/screenshot.png, or docs/screenshot-dark.png with THEME=dark
// (one app per run: the injector is global). FONT=... picks the
// font file (see screenshot_test.dart).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:complete_dependency_injector_flutter/complete_dependency_injector_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/main.dart';
import 'package:thread_suit/platform/claude_platform.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/link_service.dart';
import 'package:thread_suit/services/workspace_service.dart';

final now = DateTime.now().toUtc();
String ago(int minutes) => now.subtract(Duration(minutes: minutes)).toIso8601String();

/// One fictional thread: a project thread (with [project]) or a plain Code session.
class Fake {
  final String id;
  final String? project;
  final String folder;
  final List<(bool you, int minutesAgo, String text)> messages;
  final List<Map<String, String>> links;
  final bool read;
  final bool asleep;
  final String? title;
  Fake(this.id, this.folder, this.messages,
      {this.project, this.links = const [], this.read = false, this.asleep = false, this.title});
}

final projects = {'Acme Web': 'chan_DEMOACME', 'Pocket Weather': 'chan_DEMOWEATHER'};

final threads = [
  Fake('t1', '/home/sam/code/acme-web', project: 'Acme Web', [
    (true, 42, 'The checkout button double-charges on slow networks. Can you find out why?'),
    (false, 31, 'Found it: the button turns itself back on before the payment request settles, so a second tap '
        'sends a second charge. I opened PR #482, which keeps it disabled until the request finishes and adds a '
        'test that taps twice on a slow network.'),
    (true, 12, 'Nice. Does it also cover the Apple Pay sheet?'),
    (false, 3, 'Yes. The sheet goes through the same submit handler, so it gets the fix too. I added a second '
        'test for it; both pass.'),
  ], links: [
    {'kind': 'pullRequest', 'provider_name': 'GitHub', 'key': '#482', 'title': 'Keep checkout disabled until payment settles', 'state': 'open', 'url': 'https://example.com/acme/web/pull/482'},
    {'kind': 'issue', 'provider_name': 'Tracker', 'key': 'WEB-311', 'title': 'Customers charged twice on 3G', 'state': 'In Review', 'url': 'https://example.com/tracker/WEB-311'},
  ]),
  Fake('t2', '/home/sam/code/acme-web', project: 'Acme Web', read: true, [
    (true, 190, 'Tailor the dark mode palette so every text color passes WCAG AA.'),
    (false, 150, 'Done. Six colors were below 4.5:1; I nudged them without changing the brand hues. '
        'Contrast now passes AA on every screen, and PR #479 is merged.'),
  ], links: [
    {'kind': 'pullRequest', 'provider_name': 'GitHub', 'key': '#479', 'title': 'Dark mode colors that pass AA', 'state': 'merged', 'url': 'https://example.com/acme/web/pull/479'},
  ]),
  Fake('t3', '/home/sam/code/pocket-weather', project: 'Pocket Weather', [
    (true, 75, "Why does the forecast sometimes say 'cloudy with a chance of null'?"),
    (false, 20, 'When the weather service skips the precipitation field, we print it as is. I made the missing '
        'value say "no rain expected" and added a test with a real response that leaves it out.'),
  ], links: [
    {'kind': 'issue', 'provider_name': 'Tracker', 'key': 'PW-58', 'title': 'Forecast text shows "null"', 'state': 'In Progress', 'url': 'https://example.com/tracker/PW-58'},
  ]),
  Fake('t4', '/home/sam/code/pocket-weather', project: 'Pocket Weather', asleep: true, read: true, [
    (true, 600, 'Ship 2.3 to the beta testers once the release notes are approved.'),
    (false, 590, 'Ready to go. I\'ll upload it as soon as the notes are approved.'),
  ]),
  Fake('t5', '/home/sam/code/pocket-weather', read: true, title: 'Refactor the radar tile cache', [
    (true, 300, 'Refactor the radar tile cache so it stops refetching tiles we already have.'),
    (false, 280, 'The cache keyed tiles by URL, and the URL has a timestamp in it, so nothing ever hit. '
        'It now keys by zoom, x and y. Scrolling the radar makes 80% fewer requests.'),
  ]),
  Fake('t6', '/home/sam/code/acme-web', title: 'Hem the CI pipeline: cut build time in half', [
    (true, 55, 'Our CI takes 18 minutes. Can you take it in a bit?'),
    (false, 8, 'Down to 8 minutes: tests now run in 4 parallel shards and dependencies are cached between runs. '
        'The slowest shard is the end-to-end suite at 7 minutes.'),
  ], links: [
    {'kind': 'pullRequest', 'provider_name': 'GitHub', 'key': '#486', 'title': 'Shard tests and cache dependencies', 'state': 'open', 'url': 'https://example.com/acme/web/pull/486'},
  ]),
];

String line(Map<String, dynamic> e) => jsonEncode(e);

/// Writes the fake Claude data under [home] and Thread Suit's own state in [data].
void writeFixture(Directory home, Directory data) {
  final sessions = Directory('${home.path}/.config/Claude/claude-code-sessions/demo/demo')..createSync(recursive: true);
  final links = <String, dynamic>{'_v': LinkService.cacheVersion};
  final seen = <String, String>{}, sleep = <String, String>{};
  for (final t in threads) {
    final cli = 'cli-${t.id}';
    final folder = Directory('${home.path}/.claude/projects/${t.folder.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}')
      ..createSync(recursive: true);
    File('${sessions.path}/local_${t.id}.json').writeAsStringSync(jsonEncode({
      'sessionId': 'local_${t.id}',
      'cliSessionId': cli,
      'cwd': t.folder,
      'title': t.title ?? 'Local session (from a project)',
      'isArchived': false,
    }));
    final lines = <String>[];
    final threadId = t.project == null ? 'local_${t.id}' : 'cmsg_THREAD${t.id.toUpperCase()}';
    if (t.project != null) {
      lines.add(line({
        'type': 'attachment',
        'attachment': {'content': 'Project: "${t.project}" (id: `${projects[t.project]}`)'},
      }));
    }
    var n = 0;
    for (final (you, minutes, text) in t.messages) {
      n++;
      final at = ago(minutes);
      if (t.project == null) {
        lines.add(line({
          'type': you ? 'user' : 'assistant',
          'timestamp': at,
          'message': {
            'content': you ? text : [{'type': 'text', 'text': text}],
          },
        }));
      } else if (you) {
        lines.add(line({
          'type': 'user',
          'timestamp': at,
          'message': {
            'content': '<wake reason="mention"><project id="${projects[t.project]}" type="project">'
                '<thread ts="$threadId"><message trigger="true" from="human" trust="principal" author-id="u" '
                'id="cmsg_${t.id}_$n" sent-at="$at">${const HtmlEscape().convert(text)}</message></thread></project></wake>',
          },
        }));
      } else {
        lines.add(line({
          'type': 'assistant',
          'timestamp': at,
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'tool_${t.id}_$n',
                'name': 'mcp__claude-code-remote__send_message',
                'input': {'session_id': '@parent', 'visibility': 'posted_to_shared_channel', 'message': text},
              },
            ],
          },
        }));
      }
    }
    File('${folder.path}/$cli.jsonl').writeAsStringSync('${lines.join('\n')}\n');
    if (t.links.isNotEmpty) links[threadId] = {'hash': 'demo', 'links': t.links, 'at': ago(1)};
    if (t.read) seen[threadId] = ago(0);
    if (t.asleep) sleep[threadId] = ago(0);
  }
  File('${data.path}/links.json').writeAsStringSync(jsonEncode(links));
  File('${data.path}/seen.json').writeAsStringSync(jsonEncode(seen));
  File('${data.path}/sleep.json').writeAsStringSync(jsonEncode(sleep));
  File('${data.path}/config.json').writeAsStringSync('{"resolve_links": false}');
}

Future<void> loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
}

void main() {
  final dark = Platform.environment['THEME'] == 'dark';
  {
    testWidgets('readme screenshot${dark ? ' (dark)' : ''}', (tester) async {
      final root = Directory.systemTemp.createTempSync('readme-shot');
      final home = Directory('${root.path}/home')..createSync();
      final data = Directory('${root.path}/data')..createSync();
      writeFixture(home, data);
      final platform = ClaudePlatform.forOS('linux', env: {'HOME': home.path});
      ClaudePlatform.current = platform;

      final font = [
        Platform.environment['FONT'],
        '/System/Library/Fonts/SFNS.ttf',
        '/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        r'C:\Windows\Fonts\segoeui.ttf',
      ].whereType<String>().firstWhere((f) => File(f).existsSync());
      final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
      await tester.runAsync(() async {
        for (final family in ['Roboto', '.AppleSystemUIFont', 'CupertinoSystemText', 'CupertinoSystemDisplay']) {
          await loadFont(family, font);
        }
        await loadFont('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      });
      tester.view.physicalSize = const Size(3200, 2000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      final key = GlobalKey();
      final injector = buildRootInjector(DataDir.at(data.path), platform);
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: InjectorRootWidget(injector: injector, child: const ThreadSuitApp())),
      );
      for (var i = 0; i < 60 && find.textContaining('AWAKE').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
      // Five tiles: the 2x3 grid, with its last cell empty.
      final ws = await tester.runAsync(() => injector.getService<WorkspaceService>());
      for (final id in ['cmsg_THREADT1', 'cmsg_THREADT3', 'local_t6', 'cmsg_THREADT2', 'local_t5']) {
        ws!.open(id);
      }
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('docs/screenshot${dark ? '-dark' : ''}.png').writeAsBytesSync(png!.buffer.asUint8List());
        await injector.dispose();
      });
      root.deleteSync(recursive: true);
    });
  }
}
