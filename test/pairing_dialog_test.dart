import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/services/peer_service.dart';
import 'package:thread_suit/ui/computers.dart';

// Kept apart from peer_test.dart: a widget test swaps in Flutter's fake
// HttpClient for its whole file, which would break the real-socket tests.
void main() {
  testWidgets('the asked computer shows the code and answers Yes or No', (tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: IncomingPairingDialog(pairing: const IncomingPairing('id', 'Laptop', '042917'), onAnswer: answers.add),
      ),
    );
    expect(find.text('Pair with Laptop?'), findsOneWidget);
    expect(find.text('042 917'), findsOneWidget);
    await tester.tap(find.text('Yes, they match'));
    await tester.tap(find.text('No'));
    expect(answers, [true, false]);
  });
}
