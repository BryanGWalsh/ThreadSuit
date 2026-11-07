import 'dart:convert';
import 'dart:io';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:rxdart/rxdart.dart';

/// A thread id to timestamp map, kept in a stream and saved to a JSON file.
class TimestampStore implements InjectableWithDisposeInterface {
  final String _path;
  late final BehaviorSubject<Map<String, DateTime>> _map;

  Stream<Map<String, DateTime>> get stream => _map.stream;
  Map<String, DateTime> get value => _map.value;

  TimestampStore(this._path) {
    _map = BehaviorSubject.seeded(_load());
  }

  void set(Map<String, DateTime> next) {
    _map.add(next);
    final tmp = File('$_path.tmp');
    tmp.writeAsStringSync(jsonEncode(next.map((k, v) => MapEntry(k, v.toUtc().toIso8601String()))));
    tmp.renameSync(_path);
  }

  Map<String, DateTime> _load() {
    try {
      final raw = jsonDecode(File(_path).readAsStringSync()) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(k, DateTime.parse(v as String)));
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> dispose() => _map.close();
}
