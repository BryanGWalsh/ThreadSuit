import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/claude_platform.dart';

/// Thread Suit's own state folder. Override with THREAD_SUIT_DIR.
class DataDir {
  final String path;

  DataDir._(this.path);

  /// `~/.thread-suit`, or THREAD_SUIT_DIR (see [ClaudePlatform]). The first
  /// time, an existing `~/.thread-dashboard` (the app's old name) is moved
  /// there.
  factory DataDir.resolve([ClaudePlatform? platform]) {
    final os = platform ?? ClaudePlatform.current;
    if (os.appDataDirOverride == null) migrateLegacy(os.legacyAppDataDir, os.appDataDir);
    return DataDir.at(os.appDataDir);
  }

  /// Moves [from] to [to] if [to] doesn't exist yet. If moving fails (for
  /// example across drives), copies instead and leaves [from] in place.
  /// Returns whether anything was moved or copied.
  static bool migrateLegacy(String from, String to) {
    final old = Directory(from);
    if (!old.existsSync() || FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) return false;
    try {
      old.renameSync(to);
    } on FileSystemException {
      for (final e in old.listSync(recursive: true)) {
        final target = p.join(to, p.relative(e.path, from: from));
        if (e is Directory) {
          Directory(target).createSync(recursive: true);
        } else if (e is File) {
          File(target).parent.createSync(recursive: true);
          e.copySync(target);
        }
      }
    }
    return true;
  }

  factory DataDir.at(String path) {
    final dir = DataDir._(path);
    Directory(dir.outbox).createSync(recursive: true);
    return dir;
  }

  String get config => p.join(path, 'config.json');
  String get cache => p.join(path, 'cache.json');
  String get links => p.join(path, 'links.json');
  String get projects => p.join(path, 'projects.json');
  String get seen => p.join(path, 'seen.json');
  String get sleep => p.join(path, 'sleep.json');
  String get titles => p.join(path, 'titles.json');
  String get ui => p.join(path, 'ui.json');
  String get outbox => p.join(path, 'outbox');
}
