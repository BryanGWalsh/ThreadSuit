import 'dart:convert';
import 'dart:io';

import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:rxdart/rxdart.dart';

import 'data_dir.dart';

/// Light or dark, as you chose with the switch in the title bar; until you
/// choose, Thread Suit follows the system. Kept in `ui.json`.
class ThemeService implements InjectableWithDisposeInterface {
  final String _path;
  late final BehaviorSubject<ThemeMode> _mode;

  ThemeService(DataDir dir) : _path = dir.ui {
    _mode = BehaviorSubject.seeded(_load());
  }

  Stream<ThemeMode> get modeStream => _mode.stream;
  ThemeMode get mode => _mode.value;

  void set(ThemeMode mode) {
    if (mode == _mode.value) return;
    _mode.add(mode);
    Map<String, dynamic> ui = {};
    try {
      ui = jsonDecode(File(_path).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    if (mode == ThemeMode.system) {
      ui.remove('theme');
    } else {
      ui['theme'] = mode.name;
    }
    final tmp = File('$_path.tmp')..writeAsStringSync(jsonEncode(ui));
    tmp.renameSync(_path);
  }

  ThemeMode _load() {
    try {
      final ui = jsonDecode(File(_path).readAsStringSync()) as Map<String, dynamic>;
      return switch (ui['theme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      return ThemeMode.system;
    }
  }

  @override
  Future<void> dispose() => _mode.close();
}
