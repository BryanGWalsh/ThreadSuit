import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/models/models.dart';
import 'package:thread_suit/ui/thread_column.dart';

void main() {
  test('a message with kind notes is working notes; others are replies', () {
    ThreadMessage m(String? kind) => ThreadMessage.fromJson({
      'id': 'x',
      'from_human': false,
      'sent_at': '2026-11-07T10:00:00Z',
      'text': 't',
      'kind': ?kind,
    });
    expect(m('notes').isNotes, isTrue);
    expect(m(null).isNotes, isFalse);
    expect(m('event').isNotes, isFalse);
  });

  testWidgets('notes are labelled, start collapsed to 3 lines, and expand on click', (tester) async {
    final long = List.generate(12, (i) => 'Line ${i + 1} of the report.').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotesBubble(
            message: ThreadMessage(
              id: 'n',
              author: 'Claude',
              fromHuman: false,
              sentAt: DateTime.now(),
              text: long,
              isNotes: true,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Working notes from this computer'), findsOneWidget);
    final collapsed = tester.widget<Text>(find.byKey(const ValueKey('notes-collapsed')));
    expect(collapsed.maxLines, 3);
    expect(find.text('Show more'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('notes-collapsed')), findsNothing);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('notes-collapsed')), findsOneWidget);
  });
}
