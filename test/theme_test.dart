import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/main.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/theme_service.dart';
import 'package:thread_suit/ui/app_theme.dart';

void main() {
  late DataDir dir;
  setUp(() => dir = DataDir.at(Directory.systemTemp.createTempSync('theme').path));

  test('follows the system until you choose, then remembers the choice', () async {
    expect(ThemeService(dir).mode, ThemeMode.system);
    final svc = ThemeService(dir)..set(ThemeMode.dark);
    expect(ThemeService(dir).mode, ThemeMode.dark);
    svc.set(ThemeMode.light);
    expect(ThemeService(dir).mode, ThemeMode.light);
    svc.set(ThemeMode.system);
    expect(ThemeService(dir).mode, ThemeMode.system);
    File(dir.ui).writeAsStringSync('not json');
    expect(ThemeService(dir).mode, ThemeMode.system);
    await svc.dispose();
  });

  testWidgets('the switch flips the theme and shows the one on screen', (tester) async {
    final svc = ThemeService(dir);
    await tester.pumpWidget(
      StreamBuilder<ThemeMode>(
        stream: svc.modeStream,
        initialData: svc.mode,
        builder: (_, mode) => MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode.data!,
          home: Scaffold(appBar: AppBar(actions: [ThemeToggle(themes: svc)])),
        ),
      ),
    );
    Brightness shown() => Theme.of(tester.element(find.byType(ThemeToggle))).brightness;
    expect(shown(), Brightness.light); // the test's system theme is light
    expect(tester.widget<Switch>(find.byKey(const ValueKey('theme-toggle'))).value, isFalse);

    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(svc.mode, ThemeMode.dark);
    expect(shown(), Brightness.dark);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('theme-toggle'))).value, isTrue);
    expect(ThemeService(dir).mode, ThemeMode.dark); // saved

    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(shown(), Brightness.light);
    await svc.dispose();
  });
}
