import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/ui/tile_grid.dart';

void main() {
  test('rows and columns for 1 to 12 tiles', () {
    final expected = {
      1: (rows: 1, cols: 1),
      2: (rows: 1, cols: 2),
      3: (rows: 2, cols: 2),
      4: (rows: 2, cols: 2),
      5: (rows: 2, cols: 3),
      6: (rows: 2, cols: 3),
      7: (rows: 3, cols: 3),
      8: (rows: 3, cols: 3),
      9: (rows: 3, cols: 3),
      10: (rows: 3, cols: 4),
      11: (rows: 3, cols: 4),
      12: (rows: 3, cols: 4),
    };
    for (final MapEntry(key: n, value: grid) in expected.entries) {
      expect(TileGrid.gridFor(n), grid, reason: '$n tiles');
    }
    expect(TileGrid.gridFor(0), (rows: 0, cols: 0));
  });

  Future<List<Rect>> layout(WidgetTester tester, int n) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TileGrid(children: [for (var i = 0; i < n; i++) ColoredBox(key: ValueKey(i), color: Colors.blue)]),
      ),
    );
    return [for (var i = 0; i < n; i++) tester.getRect(find.byKey(ValueKey(i)))];
  }

  testWidgets('a short last row keeps the cell size and is left-aligned, row by row', (tester) async {
    // 3 tiles in 2x2: top left, top right, bottom left at half width.
    var r = await layout(tester, 3);
    expect(r[0], const Rect.fromLTWH(0, 0, 600, 450));
    expect(r[1], const Rect.fromLTWH(600, 0, 600, 450));
    expect(r[2], const Rect.fromLTWH(0, 450, 600, 450));

    // 7 tiles in 3x3: the last one takes a third of the bottom row, on the left.
    r = await layout(tester, 7);
    expect(r[6], const Rect.fromLTWH(0, 600, 400, 300));
    expect(r[3].top, 300);

    // 1 tile fills everything; 5 tiles are two rows of three.
    expect((await layout(tester, 1)).single, const Rect.fromLTWH(0, 0, 1200, 900));
    r = await layout(tester, 5);
    expect(r[4], const Rect.fromLTWH(400, 450, 400, 450));
  });
}
