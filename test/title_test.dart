import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/models/models.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/title_service.dart';
import 'package:thread_suit/ui/editable_title.dart';

ThreadSummary thread(String id, String title) => ThreadSummary(
  threadId: id,
  sessionId: 's-$id',
  title: title,
  state: ThreadState.unknown,
  lastActivityAt: DateTime(2026, 11, 6),
  resolved: false,
  messages: const [],
);

void main() {
  group('TitleService', () {
    late DataDir dir;
    setUp(() => dir = DataDir.at(Directory.systemTemp.createTempSync('titles').path));

    test('renames, clears with an empty name, and keeps names across restarts', () async {
      final svc = TitleService(dir);
      svc.rename('t1', '  My   build  ');
      expect(svc.value, {'t1': 'My build'});
      expect(TitleService(dir).value, {'t1': 'My build'});
      svc.rename('t1', '   ');
      expect(svc.value, isEmpty);
      expect(TitleService(dir).value, isEmpty);
      await svc.dispose();
    });

    test('your name wins over every other title, and the original is kept', () {
      final out = TitleService.apply([thread('t1', 'Local session (from a project)'), thread('t2', 'Real title')], {
        't1': 'Release checklist',
      });
      expect(out.map((t) => (t.title, t.originalTitle)), [
        ('Release checklist', 'Local session (from a project)'),
        ('Real title', null),
      ]);
      expect(out.first.threadId, 't1');
      expect(out.first.sessionId, 's-t1');
    });

    test('never writes outside its own file', () {
      TitleService(dir).rename('t1', 'x');
      expect(Directory(dir.path).listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toSet(), {
        'outbox',
        'titles.json',
      });
    });
  });

  group('EditableTitle', () {
    Future<List<String>> pump(WidgetTester tester, {String title = 'Fix login', String? original}) async {
      final renames = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 400,
                  child: EditableTitle(title: title, originalTitle: original, onRename: renames.add),
                ),
                const TextField(key: ValueKey('elsewhere')),
              ],
            ),
          ),
        ),
      );
      return renames;
    }

    Future<void> startEditing(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('rename-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('Enter saves the new name', (tester) async {
      final renames = await pump(tester);
      await startEditing(tester);
      expect(find.byKey(const ValueKey('rename-field')), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('rename-field'))).controller!.text, 'Fix login');
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Login bug');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(renames, ['Login bug']);
      expect(find.byKey(const ValueKey('rename-field')), findsNothing);
    });

    testWidgets('Esc cancels', (tester) async {
      final renames = await pump(tester);
      await startEditing(tester);
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Nope');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(renames, isEmpty);
      expect(find.text('Fix login'), findsOneWidget);
    });

    testWidgets('clicking away saves', (tester) async {
      final renames = await pump(tester);
      await startEditing(tester);
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Blurred');
      await tester.tap(find.byKey(const ValueKey('elsewhere')));
      await tester.pumpAndSettle();
      expect(renames, ['Blurred']);
    });

    testWidgets('empty, or the original title, clears the rename; unchanged does nothing', (tester) async {
      var renames = await pump(tester, title: 'Mine', original: 'Theirs');
      await startEditing(tester);
      await tester.enterText(find.byKey(const ValueKey('rename-field')), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(renames, ['']);

      renames = await pump(tester, title: 'Mine', original: 'Theirs');
      await startEditing(tester);
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Theirs');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(renames, ['']);

      renames = await pump(tester, title: 'Mine', original: 'Theirs');
      await startEditing(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(renames, isEmpty);
    });

    testWidgets('a renamed title shows its original on hover', (tester) async {
      await pump(tester, title: 'Mine', original: 'Theirs');
      expect(find.byTooltip('Renamed from: Theirs'), findsOneWidget);
    });
  });
}
