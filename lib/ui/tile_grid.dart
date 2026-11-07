import 'dart:math';

import 'package:flutter/material.dart';

/// Lays tiles out in a grid that fills the space, row by row: 1 tile takes
/// the whole area, 2 sit side by side, 3-4 form 2x2, 5-6 two rows of 3, 7-9
/// 3x3 (and the pattern continues: 10-12 three rows of 4). Every tile has the
/// same cell size: a short last row is left-aligned, not stretched.
class TileGrid extends StatelessWidget {
  final List<Widget> children;
  const TileGrid({super.key, required this.children});

  /// The grid for [n] tiles.
  static ({int rows, int cols}) gridFor(int n) {
    if (n <= 0) return (rows: 0, cols: 0);
    if (n <= 2) return (rows: 1, cols: n);
    final cols = sqrt(n).ceil();
    return (rows: (n / cols).ceil(), cols: cols);
  }

  @override
  Widget build(BuildContext context) {
    final n = children.length;
    final (:rows, :cols) = gridFor(n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows; r++)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < cols; c++)
                  Expanded(child: r * cols + c < n ? children[r * cols + c] : const SizedBox.shrink()),
              ],
            ),
          ),
      ],
    );
  }
}
