import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/platform/claude_platform.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/local_threads_service.dart';
import 'package:thread_suit/services/transcript_parser.dart';

ClaudePlatform fake(String os, Map<String, String> env, {Set<String> files = const {}}) =>
    ClaudePlatform.forOS(os, env: env, fileExists: files.contains);

void main() {
  group('macOS', () {
    final mac = fake('macos', {'HOME': '/Users/ann', 'PATH': '/usr/bin'});

    test('paths', () {
      expect(mac, isA<MacOSPlatform>());
      expect(mac.desktopSessionsDir, '/Users/ann/Library/Application Support/Claude/claude-code-sessions');
      expect(mac.transcriptsDir, '/Users/ann/.claude/projects');
      expect(mac.runningSessionsDir, '/Users/ann/.claude/sessions');
      expect(mac.appDataDir, '/Users/ann/.thread-suit');
    });

    test('tools', () {
      expect(mac.toolEnvironment['PATH'], '/Users/ann/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin');
      expect(mac.claudeBinary, 'claude');
      expect(
        fake('macos', {'HOME': '/Users/ann'}, files: {'/Users/ann/.local/bin/claude'}).claudeBinary,
        '/Users/ann/.local/bin/claude',
      );
      expect(mac.openUrlCommand('https://x.dev'), ['open', 'https://x.dev']);
      expect(mac.usesCommandKey, isTrue);
      expect(mac.sendShortcutLabel, '⌘↩');
      expect(mac.processCheckCommand(42), ['/bin/kill', '-0', '42']);
      expect(mac.isProcessAliveFromOutput(42, 0, ''), isTrue);
      expect(mac.isProcessAliveFromOutput(42, 1, ''), isFalse);
    });
  });

  group('Linux', () {
    test('paths, with and without XDG_CONFIG_HOME', () {
      final linux = fake('linux', {'HOME': '/home/ann'});
      expect(linux, isA<LinuxPlatform>());
      expect(linux.claudeDesktopDir, '/home/ann/.config/Claude');
      expect(linux.desktopSessionsDir, '/home/ann/.config/Claude/claude-code-sessions');
      expect(linux.transcriptsDir, '/home/ann/.claude/projects');
      expect(fake('linux', {'HOME': '/home/ann', 'XDG_CONFIG_HOME': '/cfg'}).claudeDesktopDir, '/cfg/Claude');
    });

    test('tools', () {
      final linux = fake('linux', {'HOME': '/home/ann'});
      expect(
        linux.toolEnvironment['PATH'],
        '/home/ann/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/snap/bin:/usr/bin:/bin',
      );
      expect(linux.openUrlCommand('https://x.dev'), ['xdg-open', 'https://x.dev']);
      expect(linux.usesCommandKey, isFalse);
      expect(linux.sendShortcutLabel, 'Ctrl+Enter');
    });

    test('other Unix-likes use the Linux layout', () {
      expect(fake('freebsd', {'HOME': '/home/ann'}), isA<LinuxPlatform>());
    });
  });

  group('Windows', () {
    final env = {
      'USERPROFILE': r'C:\Users\Ann',
      'APPDATA': r'C:\Users\Ann\AppData\Roaming',
      'Path': r'C:\Windows\System32',
      'ProgramFiles': r'C:\Program Files',
    };
    final win = fake('windows', env);

    test('paths', () {
      expect(win, isA<WindowsPlatform>());
      expect(win.desktopSessionsDir, r'C:\Users\Ann\AppData\Roaming\Claude\claude-code-sessions');
      expect(win.transcriptsDir, r'C:\Users\Ann\.claude\projects');
      expect(win.runningSessionsDir, r'C:\Users\Ann\.claude\sessions');
      expect(win.appDataDir, r'C:\Users\Ann\.thread-suit');
    });

    test('tools', () {
      // Windows spells it "Path"; the same key is kept, joined with ";".
      expect(win.toolEnvironment, {'Path': r'C:\Users\Ann\.local\bin;C:\Windows\System32'});
      expect(
        fake('windows', env, files: {r'C:\Users\Ann\.local\bin\claude.exe'}).claudeBinary,
        r'C:\Users\Ann\.local\bin\claude.exe',
      );
      expect(win.openUrlCommand('https://x.dev'), ['rundll32', 'url.dll,FileProtocolHandler', 'https://x.dev']);
      expect(win.processCheckCommand(42), ['tasklist', '/FI', 'PID eq 42', '/NH', '/FO', 'CSV']);
      expect(win.isProcessAliveFromOutput(42, 0, '"claude.exe","42","Console","1","90,000 K"'), isTrue);
      expect(win.isProcessAliveFromOutput(42, 0, 'INFO: No tasks are running which match the criteria.'), isFalse);
    });
  });

  test('overrides: CLAUDE_CONFIG_DIR and THREAD_SUIT_DIR', () {
    final p = fake('linux', {'HOME': '/home/ann', 'CLAUDE_CONFIG_DIR': '/cc', 'THREAD_SUIT_DIR': '/td'});
    expect(p.transcriptsDir, '/cc/projects');
    expect(p.runningSessionsDir, '/cc/sessions');
    expect(p.appDataDir, '/td');
  });

  group('transcript locations', () {
    test('folder names for a working directory', () {
      final p = fake('linux', {'HOME': '/h'});
      expect(p.transcriptFolderNames('/home/ann/git/my.app'), ['-home-ann-git-my-app']);
      expect(p.transcriptFolderNames('/home/ann/my_app'), ['-home-ann-my-app', '-home-ann-my_app']);
      expect(fake('windows', {}).transcriptFolderNames(r'C:\Users\Ann\app').first, 'C--Users-Ann-app');
    });

    test('SSH sessions are looked up in ssh-<id>/ first', () {
      final ssh = transcriptCandidates(
        {
          'cliSessionId': 'abc',
          'cwd': '/home/remote/app',
          'sshConfig': {'sshHost': 'me@box'},
        },
        '/t',
        'linux',
      );
      expect(ssh.first, '/t/ssh-abc/abc.jsonl');
      expect(ssh, contains('/t/-home-remote-app/abc.jsonl'));

      final local = transcriptCandidates({'cliSessionId': 'abc', 'cwd': '/home/ann/app'}, '/t', 'linux');
      expect(local.first, '/t/-home-ann-app/abc.jsonl');
      expect(transcriptCandidates({'cwd': '/x'}, '/t', 'linux'), isEmpty);
    });
  });

  test('project name and first message come from a Remote Control project transcript', () {
    final dir = Directory.systemTemp.createTempSync('proj');
    final f = File('${dir.path}/t.jsonl');
    f.writeAsStringSync(
      '${[
        jsonEncode({
          'type': 'attachment',
          'attachment': {'content': '## Where you are\n\nProject: "Ann\'s App (v2)" (id: `chan_ABC`)\n'},
        }),
        jsonEncode({
          'type': 'user',
          'timestamp': '2026-11-06T10:00:00Z',
          'message': {'content': '<wake reason="mention"><project id="chan_ABC" type="project"><thread ts="cmsg_T">'
              '<message from="human" id="cmsg_1" sent-at="2026-11-06T10:00:00Z">  fix   the\nlogin page  </message>'
              '</thread></project></wake>'},
        }),
      ].join('\n')}\n',
    );
    final state = TranscriptState()..readFrom(f);
    expect(state.projectName, "Ann's App (v2)");
    expect(state.projectId, 'chan_ABC');
    expect(state.firstPrompt, 'fix the login page');

    final back = TranscriptState.fromJson(state.toJson());
    expect(back.projectName, state.projectName);
    expect(back.firstPrompt, state.firstPrompt);
    dir.deleteSync(recursive: true);
  });

  group('data folder', () {
    test('THREAD_SUIT_DIR, and THREAD_DASHBOARD_DIR from before the rename', () {
      expect(fake('linux', {'HOME': '/h'}).appDataDir, '/h/.thread-suit');
      expect(fake('linux', {'HOME': '/h'}).legacyAppDataDir, '/h/.thread-dashboard');
      expect(fake('linux', {'HOME': '/h', 'THREAD_DASHBOARD_DIR': '/old'}).appDataDir, '/old');
      expect(
        fake('linux', {'HOME': '/h', 'THREAD_SUIT_DIR': '/new', 'THREAD_DASHBOARD_DIR': '/old'}).appDataDir,
        '/new',
      );
    });

    test('~/.thread-dashboard moves to ~/.thread-suit once', () {
      final home = Directory.systemTemp.createTempSync('home');
      final old = Directory('${home.path}/.thread-dashboard/outbox')..createSync(recursive: true);
      File('${home.path}/.thread-dashboard/seen.json').writeAsStringSync('{"a":1}');
      File('${old.path}/m1.json').writeAsStringSync('{}');

      final dir = DataDir.resolve(fake('linux', {'HOME': home.path}));
      expect(dir.path, '${home.path}/.thread-suit');
      expect(File(dir.seen).readAsStringSync(), '{"a":1}');
      expect(File('${dir.outbox}/m1.json').existsSync(), isTrue);
      expect(Directory('${home.path}/.thread-dashboard').existsSync(), isFalse);

      // Never again once the new folder exists.
      Directory('${home.path}/.thread-dashboard').createSync();
      expect(DataDir.migrateLegacy('${home.path}/.thread-dashboard', dir.path), isFalse);
      home.deleteSync(recursive: true);
    });
  });
}
