import 'dart:convert';
import 'dart:io';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:rxdart/rxdart.dart';

import '../models/models.dart';
import 'data_dir.dart';

/// Your own names for threads, kept only in Thread Suit (`titles.json`,
/// thread id to name). Claude's files and the thread's real title are never
/// touched. A name here wins over every other title source.
class TitleService implements InjectableWithDisposeInterface {
  final String _path;
  late final BehaviorSubject<Map<String, String>> _titles;

  TitleService(DataDir dir) : _path = dir.titles {
    _titles = BehaviorSubject.seeded(_load());
  }

  Stream<Map<String, String>> get titlesStream => _titles.stream;
  Map<String, String> get value => _titles.value;

  /// Names [threadId] [title]. An empty name clears it, so the thread shows
  /// its own title again.
  void rename(String threadId, String title) {
    final name = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    final next = {...value};
    if (name.isEmpty) {
      if (next.remove(threadId) == null) return;
    } else {
      if (next[threadId] == name) return;
      next[threadId] = name;
    }
    _titles.add(next);
    final tmp = File('$_path.tmp')..writeAsStringSync(jsonEncode(next));
    tmp.renameSync(_path);
  }

  /// [threads] with your names applied.
  static List<ThreadSummary> apply(List<ThreadSummary> threads, Map<String, String> titles) => [
    for (final t in threads)
      if (titles[t.threadId] case final name? when name != t.title) t.renamed(name) else t,
  ];

  Map<String, String> _load() {
    try {
      return (jsonDecode(File(_path).readAsStringSync()) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> dispose() => _titles.close();
}
