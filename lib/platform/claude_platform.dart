import 'dart:io';

import 'package:path/path.dart' as p;

/// Everything that differs between macOS, Linux and Windows, in one place.
/// The rest of `lib/` asks this class instead of checking the OS.
///
/// [ClaudePlatform.current] is chosen once at startup from the running OS.
/// Tests build a specific one with [ClaudePlatform.forOS] and a fake
/// environment and file check, so every OS can be tested on any machine.
abstract class ClaudePlatform {
  /// Environment variables (normally [Platform.environment]).
  final Map<String, String> env;

  /// Whether a file exists (normally [File.existsSync]); used to find `claude`.
  final bool Function(String path) fileExists;

  ClaudePlatform(this.env, this.fileExists);

  static ClaudePlatform? _current;

  /// The platform for this OS. Set it in tests to swap the whole layer.
  static ClaudePlatform get current => _current ??= ClaudePlatform.forOS(Platform.operatingSystem);
  static set current(ClaudePlatform value) => _current = value;

  /// [os] is a [Platform.operatingSystem] value: `macos`, `linux`, `windows`.
  /// Other Unix-likes get the Linux layout.
  factory ClaudePlatform.forOS(String os, {Map<String, String>? env, bool Function(String)? fileExists}) {
    final e = env ?? Platform.environment;
    final exists = fileExists ?? (String f) => File(f).existsSync();
    return switch (os) {
      'macos' => MacOSPlatform(e, exists),
      'windows' => WindowsPlatform(e, exists),
      _ => LinuxPlatform(e, exists),
    };
  }

  /// `macos`, `linux` or `windows`.
  String get name;

  p.Context get paths;

  String get home;

  /// Where the Claude desktop app keeps its data.
  String get claudeDesktopDir;

  /// [claudeDesktopDir] at its default place, relative to the home folder
  /// and written with `/`. Used to find the folder on another computer of
  /// this OS over SSH, where the environment isn't known.
  String get desktopDirFromHome;

  /// The command that copies a folder from another computer into
  /// [localDir], over the user's own SSH login to [host] (a name from their
  /// SSH config, or `user@host`). [remoteDir] is relative to the remote home
  /// folder. Only session records and transcripts (`.json`, `.jsonl`) are
  /// copied, and only what changed. Null where Thread Suit can't do that yet.
  List<String>? mirrorCommand({required String host, required String remoteDir, required String localDir});

  /// Runs [command] on another computer over the user's own SSH login to
  /// [host]. BatchMode makes ssh fail instead of asking for a password,
  /// since nobody can type one; keys or an agent are needed. Every OS this
  /// app runs on ships an OpenSSH client.
  List<String> sshCommand(String host, String command) => [
    'ssh',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=10',
    host,
    command,
  ];

  /// A shell command, for a computer of this OS reached over SSH, that runs
  /// `claude` with [args]: the native installer's location if present,
  /// otherwise whatever `PATH` finds. Null where that isn't supported yet.
  String? remoteClaudeCommand(List<String> args);

  /// A shell command, for a computer of this OS reached over SSH, that exits
  /// 0 only if process [pid] is running. Null where that isn't supported yet.
  String? remoteProcessCheck(int pid);

  /// The desktop app's records of Code sessions (title, folder, transcript id).
  String get desktopSessionsDir => paths.join(claudeDesktopDir, 'claude-code-sessions');

  /// Claude Code's own folder. `CLAUDE_CONFIG_DIR` moves it, as it does for
  /// Claude Code itself.
  String get claudeCodeDir {
    final override = env['CLAUDE_CONFIG_DIR'];
    return override != null && override.isNotEmpty ? override : paths.join(home, '.claude');
  }

  /// Session transcripts, one folder per working directory.
  String get transcriptsDir => paths.join(claudeCodeDir, 'projects');

  /// One file per running Claude Code process.
  String get runningSessionsDir => paths.join(claudeCodeDir, 'sessions');

  /// Thread Suit's own state, `~/.thread-suit`. `THREAD_SUIT_DIR` moves it
  /// (`THREAD_DASHBOARD_DIR`, from before the rename, still works).
  String get appDataDir {
    final override = appDataDirOverride;
    return override ?? paths.join(home, '.thread-suit');
  }

  /// The folder set by environment variable, if any.
  String? get appDataDirOverride {
    for (final key in ['THREAD_SUIT_DIR', 'THREAD_DASHBOARD_DIR']) {
      final v = env[key];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Where the app kept its state when it was called Thread Dashboard.
  String get legacyAppDataDir => paths.join(home, '.thread-dashboard');

  /// Folder names Claude Code may have used for a working directory's
  /// transcripts, most likely first. Current versions replace every
  /// character that isn't a letter or digit with `-`; older ones replaced
  /// only `/` and `.`.
  List<String> transcriptFolderNames(String cwd) =>
      {cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-'), cwd.replaceAll(RegExp(r'[/\\.]'), '-')}.toList();

  /// Folders to search for tools such as `claude`, `gh` and `curl`, added in
  /// front of `PATH`: apps started from Finder, a desktop launcher or the
  /// Start menu get a minimal `PATH`.
  List<String> get extraToolDirs;

  /// The environment for running tools, with [extraToolDirs] on `PATH`.
  Map<String, String> get toolEnvironment {
    final sep = name == 'windows' ? ';' : ':';
    final key = env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
    final existing = env[key] ?? defaultPath;
    return {
      key: [...extraToolDirs, existing].join(sep),
    };
  }

  String get defaultPath;

  /// The `claude` executable: the native installer's location if present,
  /// otherwise whatever `PATH` finds.
  String get claudeBinary;

  /// The command that opens [url] in the default browser.
  List<String> openUrlCommand(String url);

  /// The command that checks whether process [pid] is running; its result
  /// is read by [isProcessAliveFromOutput].
  List<String> processCheckCommand(int pid);

  /// For platforms whose process check prints rather than sets an exit code.
  bool isProcessAliveFromOutput(int pid, int exitCode, String stdout) => exitCode == 0;

  /// Whether shortcuts use ⌘ (macOS) rather than Ctrl.
  bool get usesCommandKey => false;

  /// How the send shortcut is written for this OS.
  String get sendShortcutLabel => usesCommandKey ? '⌘↩' : 'Ctrl+Enter';

  /// Opens [url] in the default browser. Only `https://` URLs are opened.
  Future<void> openUrl(String url) async {
    if (!url.startsWith('https://')) return;
    final cmd = openUrlCommand(url);
    await Process.run(cmd.first, cmd.sublist(1));
  }

  /// Whether process [pid] is still running.
  Future<bool> isProcessAlive(int pid) async {
    final cmd = processCheckCommand(pid);
    final r = await Process.run(cmd.first, cmd.sublist(1));
    return isProcessAliveFromOutput(pid, r.exitCode, '${r.stdout}');
  }
}

abstract class _UnixPlatform extends ClaudePlatform {
  _UnixPlatform(super.env, super.fileExists);

  @override
  p.Context get paths => p.posix;

  @override
  String get home => env['HOME'] ?? '';

  @override
  String get defaultPath => '/usr/bin:/bin';

  @override
  String get claudeBinary {
    final local = paths.join(home, '.local/bin/claude');
    return fileExists(local) ? local : 'claude';
  }

  @override
  List<String> processCheckCommand(int pid) => ['/bin/kill', '-0', '$pid'];

  /// rsync over [sshCommand]'s ssh options.
  @override
  List<String>? mirrorCommand({required String host, required String remoteDir, required String localDir}) => [
    'rsync',
    '-az',
    '--delete',
    '--prune-empty-dirs',
    '--include=*/',
    '--include=*.json',
    '--include=*.jsonl',
    '--exclude=*',
    '-e',
    'ssh -o BatchMode=yes -o ConnectTimeout=10',
    '$host:$remoteDir/',
    '$localDir/',
  ];

  /// [value] as one POSIX shell word.
  static String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// Wrapped in `sh -c`, since the login shell on the other end may not be
  /// a POSIX one (fish, for example).
  @override
  String remoteClaudeCommand(List<String> args) {
    final script =
        r'c="$HOME/.local/bin/claude"; [ -x "$c" ] || c=claude; cd /tmp && exec "$c" ' + args.map(shellQuote).join(' ');
    return 'sh -c ${shellQuote(script)}';
  }

  @override
  String remoteProcessCheck(int pid) => 'kill -0 $pid';
}

class MacOSPlatform extends _UnixPlatform {
  MacOSPlatform(super.env, super.fileExists);

  @override
  String get name => 'macos';

  @override
  String get claudeDesktopDir => paths.join(home, desktopDirFromHome);

  @override
  String get desktopDirFromHome => 'Library/Application Support/Claude';

  @override
  bool get usesCommandKey => true;

  @override
  List<String> get extraToolDirs => [paths.join(home, '.local/bin'), '/opt/homebrew/bin', '/usr/local/bin'];

  @override
  List<String> openUrlCommand(String url) => ['open', url];
}

class LinuxPlatform extends _UnixPlatform {
  LinuxPlatform(super.env, super.fileExists);

  @override
  String get name => 'linux';

  /// `$XDG_CONFIG_HOME/Claude`, normally `~/.config/Claude`.
  @override
  String get claudeDesktopDir {
    final xdg = env['XDG_CONFIG_HOME'];
    return paths.join(xdg != null && xdg.isNotEmpty ? xdg : paths.join(home, '.config'), 'Claude');
  }

  @override
  String get desktopDirFromHome => '.config/Claude';

  @override
  List<String> get extraToolDirs => [
    paths.join(home, '.local/bin'),
    '/home/linuxbrew/.linuxbrew/bin',
    '/usr/local/bin',
    '/snap/bin',
  ];

  @override
  List<String> openUrlCommand(String url) => ['xdg-open', url];
}

class WindowsPlatform extends ClaudePlatform {
  WindowsPlatform(super.env, super.fileExists);

  @override
  String get name => 'windows';

  @override
  p.Context get paths => p.windows;

  @override
  String get home => env['USERPROFILE'] ?? '${env['HOMEDRIVE'] ?? 'C:'}${env['HOMEPATH'] ?? r'\'}';

  /// `%APPDATA%\Claude`, normally `C:\Users\<you>\AppData\Roaming\Claude`.
  @override
  String get claudeDesktopDir => paths.join(env['APPDATA'] ?? paths.join(home, 'AppData', 'Roaming'), 'Claude');

  @override
  String get desktopDirFromHome => 'AppData/Roaming/Claude';

  /// Windows has no rsync, so reading another computer isn't supported here yet.
  @override
  List<String>? mirrorCommand({required String host, required String remoteDir, required String localDir}) => null;

  /// Windows computers aren't read over SSH yet, so nothing is run on them.
  @override
  String? remoteClaudeCommand(List<String> args) => null;

  @override
  String? remoteProcessCheck(int pid) => null;

  @override
  String get defaultPath => r'C:\Windows\System32;C:\Windows';

  @override
  List<String> get extraToolDirs => [paths.join(home, '.local', 'bin')];

  @override
  String get claudeBinary {
    final local = paths.join(home, '.local', 'bin', 'claude.exe');
    return fileExists(local) ? local : 'claude';
  }

  @override
  List<String> openUrlCommand(String url) => ['rundll32', 'url.dll,FileProtocolHandler', url];

  @override
  List<String> processCheckCommand(int pid) => ['tasklist', '/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'];

  /// `tasklist` exits 0 either way; a running process appears as a CSV row.
  @override
  bool isProcessAliveFromOutput(int pid, int exitCode, String stdout) => exitCode == 0 && stdout.contains('"$pid"');
}
